package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"io"
	"log"
	"mime"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func handler(provider RoutingProvider, cameras ...*cameraService) http.Handler {
	return handlerWithWeather(provider, cameras, nil)
}

func handlerWithWeather(provider RoutingProvider, cameras []*cameraService, weather *weatherService) http.Handler {
	return handlerWithTraffic(provider, cameras, weather, nil)
}

func handlerWithTraffic(provider RoutingProvider, cameras []*cameraService, weather *weatherService, traffic *trafficService) http.Handler {
	mux := http.NewServeMux()
	if len(cameras) > 0 {
		mux.HandleFunc("POST /v1/cameras", cameras[0].serveHTTP)
	}
	if weather != nil {
		mux.HandleFunc("POST /v1/weather", weather.serveHTTP)
	}
	if traffic != nil {
		mux.HandleFunc("POST /v1/traffic", traffic.serveHTTP)
		mux.HandleFunc("POST /v1/traffic/route", traffic.serveRouteHTTP)
	}
	write := func(w http.ResponseWriter, status int, v any) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		w.WriteHeader(status)
		_ = json.NewEncoder(w).Encode(v)
	}
	fail := func(w http.ResponseWriter, err error) {
		e := apiError("upstream_unavailable")
		var a *APIError
		if errors.As(err, &a) {
			e = a
		}
		status := 503
		switch e.Code {
		case "invalid_request", "unsupported_option":
			status = 400
		case "limit_exceeded":
			status = 413
		case "no_route", "cannot_snap":
			status = 422
		case "upstream_timeout":
			status = 504
		case "invalid_upstream_response":
			status = 502
		}
		write(w, status, map[string]any{"error": e})
	}
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) { write(w, 200, map[string]string{"status": "ok"}) })
	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
		defer cancel()
		if err := provider.Ready(ctx); err != nil {
			fail(w, err)
			return
		}
		write(w, 200, map[string]string{"status": "ready"})
	})
	mux.HandleFunc("GET /v1/capabilities", func(w http.ResponseWriter, r *http.Request) {
		options := routingOptions(provider)
		capabilities := map[string]any{"apiVersion": "1", "profiles": []string{"car"}, "objectives": routingObjectives(provider), "routingOptions": options, "detourOptions": catalogDetourOptions(options), "preferences": []string{"tolls", "motorways", "ferries"}, "preferenceValues": []string{"neutral", "avoid"}, "maxWaypoints": 10, "maxAlternatives": 2, "geometryEncoding": "polyline6", "annotations": []string{}, "timingMethod": "maneuver_interpolation"}
		if len(cameras) > 0 {
			capabilities["cameras"] = cameras[0].store.read().Dataset
		}
		if weather != nil {
			capabilities["weather"] = weather.capability()
		}
		if traffic != nil {
			capabilities["traffic"] = traffic.capability()
		}
		write(w, 200, capabilities)
	})
	// Bound simultaneous graph requests. Traefik applies external rate limits.
	slots := make(chan struct{}, 4)
	mux.HandleFunc("POST /v1/routes", func(w http.ResponseWriter, r *http.Request) {
		mediaType, _, mediaError := mime.ParseMediaType(r.Header.Get("Content-Type"))
		if mediaError != nil || mediaType != "application/json" {
			write(w, 415, map[string]any{"error": apiError("invalid_request")})
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, 16384)
		defer r.Body.Close()
		dec := json.NewDecoder(r.Body)
		dec.DisallowUnknownFields()
		var input RouteRequest
		if err := dec.Decode(&input); err != nil {
			var limit *http.MaxBytesError
			if errors.As(err, &limit) {
				fail(w, apiError("limit_exceeded"))
			} else {
				fail(w, apiError("invalid_request"))
			}
			return
		}
		if dec.Decode(new(any)) != io.EOF {
			fail(w, apiError("invalid_request"))
			return
		}
		if err := input.validateFor(routingObjectives(provider)); err != nil {
			fail(w, err)
			return
		}
		select {
		case slots <- struct{}{}:
			defer func() { <-slots }()
		default:
			w.Header().Set("Retry-After", "5")
			write(w, 429, map[string]any{"error": apiError("busy")})
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 16*time.Second)
		defer cancel()
		routes, warnings, err := provider.Routes(ctx, input)
		if err != nil {
			if r.Context().Err() != nil {
				return
			}
			if errors.Is(err, context.DeadlineExceeded) {
				err = apiError("upstream_timeout")
			}
			fail(w, err)
			return
		}
		if len(routes) == 0 {
			fail(w, apiError("invalid_upstream_response"))
			return
		}
		if warnings == nil {
			warnings = []Warning{}
		}
		if traffic != nil {
			traffic.decorate(ctx, routes, input)
		}
		if weather != nil {
			for i := range routes {
				token, expiresAt := weather.register(routes[i])
				if token != "" {
					routes[i].WeatherToken = token
					routes[i].WeatherExpiresAt = &expiresAt
				}
			}
		}
		attributions:=[]string{"© OpenStreetMap contributors — ODbL"};if traffic!=nil{attributions=traffic.routeAttributions(routes)}
		write(w, 200, RouteResponse{identifier(), time.Now().UTC(), routes, warnings, attributions, Provenance{"valhalla", "1", ""}})
	})
	return mux
}
func main() {
	syncOnce := flag.Bool("camera-sync-once", false, "Import NL cameras atomically and exit without starting HTTP")
	trafficOnce := flag.Bool("traffic-sync-once", false, "Fetch and inspect configured live traffic once; no HTTP server")
	flag.Parse()
	dir := os.Getenv("CAMERA_DATA_DIR")
	if dir == "" {
		dir = "data/cameras"
	}
	store, loadErr := newCameraStore(dir)
	if loadErr != nil {
		log.Printf("camera snapshot load failed; camera data unavailable: %v", loadErr)
	}
	if *syncOnce {
		ctx, cancel := context.WithTimeout(context.Background(), 8*time.Minute)
		defer cancel()
		if err := store.sync(ctx, defaultCameraFetcher(), time.Time{}); err != nil {
			log.Fatal(err)
		}
		snapshot := store.read()
		encoded, _ := json.Marshal(map[string]any{"dataset": snapshot.Dataset, "cameraCount": len(snapshot.Cameras), "zoneCount": len(snapshot.Zones), "verifiedZoneCount": len(snapshot.Zones) - snapshot.Dataset.IncompleteZoneCount})
		log.Print(string(encoded))
		return
	}
	base := os.Getenv("VALHALLA_BASE_URL")
	if base == "" {
		base = "http://Valhalla:8002"
	}
	if p := os.Getenv("ROUTING_PROVIDER"); p != "" && p != "valhalla" {
		log.Fatal("unsupported ROUTING_PROVIDER")
	}
	provider, err := newValhalla(base)
	if err != nil {
		log.Fatal(err)
	}
	addr := os.Getenv("LISTEN_ADDR")
	if addr == "" {
		addr = ":8080"
	}
	var router RoutingProvider = provider
	if os.Getenv("ENABLE_EXPERIMENTAL_ROUTING") == "1" {
		router = &experimentalRouter{base: provider, attributes: provider}
	}
	openMeteoBase := os.Getenv("OPEN_METEO_BASE_URL")
	if openMeteoBase == "" {
		openMeteoBase = "https://api.open-meteo.com/v1/forecast"
	}
	weatherCacheTTL := 15 * time.Minute
	if raw := os.Getenv("WEATHER_CACHE_TTL"); raw != "" {
		parsed, parseErr := time.ParseDuration(raw)
		if parseErr != nil || parsed <= 0 {
			log.Fatal("invalid WEATHER_CACHE_TTL")
		}
		weatherCacheTTL = parsed
	}
	openMeteo, weatherErr := newOpenMeteo(openMeteoBase)
	if weatherErr != nil {
		log.Fatal(weatherErr)
	}
	weatherSvc := newWeatherService([]weatherProvider{openMeteo}, weatherCacheTTL, time.Now)
	trafficConfig, trafficErr := loadTrafficConfig(os.Getenv("TRAFFIC_CONFIG"))
	if trafficErr != nil {
		log.Fatal(trafficErr)
	}
	traffic := newTrafficService(trafficConfig, provider)
	traffic.routing = router
	provider.traffic = traffic
	if *trafficOnce {
		ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
		defer cancel()
		for _, p := range traffic.providers {
			traffic.syncProvider(ctx, p)
		}
		_ = json.NewEncoder(os.Stdout).Encode(traffic.capability())
		return
	}
	srv := &http.Server{Addr: addr, Handler: handlerWithTraffic(router, []*cameraService{newCameraService(store, provider)}, weatherSvc, traffic), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 25 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 16384}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go store.runSync(ctx, defaultCameraFetcher())
	go traffic.run(ctx)
	go func() {
		<-ctx.Done()
		c, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = srv.Shutdown(c)
	}()
	log.Printf("RoadScout routing API listening on %s", addr)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}
