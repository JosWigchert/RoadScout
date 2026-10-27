package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

var testWeatherInfo = WeatherProviderInfo{
	ID:          "open-meteo",
	Name:        "Open-Meteo",
	License:     "CC BY 4.0",
	Attribution: "Weather data by Open-Meteo.com",
	Coverage:    "Worldwide; 15-minute precipitation in the Netherlands/Central Europe",
}

type fakeClock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *fakeClock) now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}
func (c *fakeClock) advance(d time.Duration) {
	c.mu.Lock()
	c.t = c.t.Add(d)
	c.mu.Unlock()
}

type fakeWeatherProvider struct {
	info     WeatherProviderInfo
	forecast func(weatherSample) sampleForecast
	err      error
	mu       sync.Mutex
	calls    int
	batches  []int
}

func (f *fakeWeatherProvider) Info() WeatherProviderInfo { return f.info }
func (f *fakeWeatherProvider) Forecast(_ context.Context, samples []weatherSample) ([]sampleForecast, error) {
	f.mu.Lock()
	f.calls++
	f.batches = append(f.batches, len(samples))
	f.mu.Unlock()
	if f.err != nil {
		return nil, f.err
	}
	out := make([]sampleForecast, len(samples))
	for i, sample := range samples {
		out[i] = f.forecast(sample)
	}
	return out, nil
}
func (f *fakeWeatherProvider) callCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.calls
}

func weatherLine(t *testing.T, lengthMeters float64, steps int) (string, []Point) {
	t.Helper()
	const latitude = 52.0
	metersPerDegree := 111320 * math.Cos(latitude*math.Pi/180)
	points := make([]Point, steps+1)
	for i := range points {
		points[i] = Point{Latitude: latitude, Longitude: 5 + (lengthMeters*float64(i)/float64(steps))/metersPerDegree}
	}
	return encodePolyline(points), points
}

func testRoute(t *testing.T, lengthMeters, durationSeconds float64) Route {
	t.Helper()
	geometry, points := weatherLine(t, lengthMeters, 40)
	return Route{
		ID:       "weather-route",
		Summary:  Summary{Distance: lengthMeters, Duration: durationSeconds},
		Geometry: Geometry{Encoding: "polyline6", Dimensions: 2, Count: len(points), Data: geometry},
		Timing:   Timing{Method: "maneuver_interpolation", Traffic: "unknown", Anchors: []Anchor{{0, 0}, {len(points) - 1, durationSeconds}}},
	}
}

func testWeatherService(t *testing.T, provider weatherProvider, clock *fakeClock, ttl time.Duration, lengthMeters, durationSeconds float64) (*weatherService, Route, routeTokenEntry) {
	t.Helper()
	service := newWeatherService([]weatherProvider{provider}, ttl, clock.now)
	route := testRoute(t, lengthMeters, durationSeconds)
	token, _ := service.register(route)
	entry, ok := service.tokens.get(token)
	if !ok {
		t.Fatal("route token was not stored")
	}
	return service, route, entry
}

func stormForecast(sample weatherSample) sampleForecast {
	start := time.Date(2026, 10, 24, 14, 0, 0, 0, time.UTC)
	if !sample.At.Before(start) && sample.At.Before(start.Add(30*time.Minute)) {
		return sampleForecast{Available: true, ProbabilityPercent: 70, IntensityMmPerHour: 0.8}
	}
	return sampleForecast{Available: true, ProbabilityPercent: 5}
}

func dryForecast(weatherSample) sampleForecast {
	return sampleForecast{Available: true, ProbabilityPercent: 5}
}

func TestWeatherStormBeforeAndAfterPassingTime(t *testing.T) {
	clock := &fakeClock{t: time.Date(2026, 10, 24, 13, 50, 0, 0, time.UTC)}
	provider := &fakeWeatherProvider{info: testWeatherInfo, forecast: stormForecast}
	service, _, entry := testWeatherService(t, provider, clock, 15*time.Minute, 10000, 1200)

	before, err := service.analyze(context.Background(), entry, time.Date(2026, 10, 24, 13, 55, 0, 0, time.UTC))
	if err != nil {
		t.Fatal(err)
	}
	if before.Recommendation != weatherRecommendationRainRisk {
		t.Fatalf("recommendation = %q, want rain_risk", before.Recommendation)
	}
	if before.Summary == nil || before.Summary.RainRiskSampleCount == 0 || before.Summary.SampleCount != 5 {
		t.Fatalf("unexpected summary: %+v", before.Summary)
	}
	if len(before.Segments) == 0 {
		t.Fatal("expected rain-risk segments")
	}
	for _, segment := range before.Segments {
		if segment.Geometry.Encoding != "polyline6" || segment.ProbabilityPercent != 70 || segment.IntensityMmPerHour != 0.8 {
			t.Fatalf("unexpected segment: %+v", segment)
		}
		points, decodeErr := decodePolyline(segment.Geometry.Data)
		if decodeErr != nil || len(points) < 2 {
			t.Fatalf("segment geometry not polyline6: %v", decodeErr)
		}
		if segment.StartMeters < 0 || segment.EndMeters > 10000 || segment.EndMeters <= segment.StartMeters {
			t.Fatalf("segment bounds out of range: %+v", segment)
		}
	}

	after, err := service.analyze(context.Background(), entry, time.Date(2026, 10, 24, 15, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatal(err)
	}
	if after.Recommendation != weatherRecommendationRoofDown {
		t.Fatalf("recommendation = %q, want roof_down", after.Recommendation)
	}
	if after.Summary == nil || after.Summary.RainRiskSampleCount != 0 {
		t.Fatalf("unexpected summary: %+v", after.Summary)
	}
	if len(after.Segments) != 0 {
		t.Fatalf("expected no segments, got %d", len(after.Segments))
	}
}

func TestWeatherDryRoute(t *testing.T) {
	clock := &fakeClock{t: time.Date(2026, 10, 24, 12, 0, 0, 0, time.UTC)}
	provider := &fakeWeatherProvider{info: testWeatherInfo, forecast: dryForecast}
	service, _, entry := testWeatherService(t, provider, clock, 15*time.Minute, 10000, 1200)
	response, err := service.analyze(context.Background(), entry, clock.now())
	if err != nil {
		t.Fatal(err)
	}
	if response.Recommendation != weatherRecommendationRoofDown {
		t.Fatalf("recommendation = %q", response.Recommendation)
	}
	if response.Summary == nil || response.Summary.MaxProbabilityPercent != 5 || response.Summary.MaxIntensityMmPerHour != 0 {
		t.Fatalf("unexpected summary: %+v", response.Summary)
	}
	if len(response.Segments) != 0 {
		t.Fatal("dry route must not have segments")
	}
}

func TestWeatherMissingSamplesBecomeUnavailable(t *testing.T) {
	clock := &fakeClock{t: time.Date(2026, 10, 24, 12, 0, 0, 0, time.UTC)}
	for _, test := range []struct {
		name      string
		available int
		want      string
	}{
		{"all missing", 0, weatherRecommendationUnavail},
		{"majority missing", 1, weatherRecommendationUnavail},
		{"minority missing", 4, weatherRecommendationUnavail},
	} {
		t.Run(test.name, func(t *testing.T) {
			seen := 0
			var mu sync.Mutex
			provider := &fakeWeatherProvider{info: testWeatherInfo, forecast: func(weatherSample) sampleForecast {
				mu.Lock()
				defer mu.Unlock()
				seen++
				if seen <= 5-test.available {
					return sampleForecast{}
				}
				return sampleForecast{Available: true, ProbabilityPercent: 5}
			}}
			service, _, entry := testWeatherService(t, provider, clock, 15*time.Minute, 10000, 1200)
			response, err := service.analyze(context.Background(), entry, clock.now())
			if err != nil {
				t.Fatal(err)
			}
			if response.Recommendation != test.want {
				t.Fatalf("recommendation = %q, want %q", response.Recommendation, test.want)
			}
			if test.want == weatherRecommendationUnavail {
				if response.Summary != nil {
					t.Fatal("summary must be omitted when unavailable")
				}
				if len(response.Segments) != 0 {
					t.Fatal("segments must be empty when unavailable")
				}
			}
		})
	}
}

func TestWeatherTimezoneHandling(t *testing.T) {
	clock := &fakeClock{t: time.Date(2026, 10, 24, 13, 0, 0, 0, time.UTC)}
	provider := &fakeWeatherProvider{info: testWeatherInfo, forecast: stormForecast}
	service, _, entry := testWeatherService(t, provider, clock, 15*time.Minute, 10000, 1200)
	cest := time.FixedZone("CEST", 2*3600)
	departure := time.Date(2026, 10, 24, 16, 0, 0, 0, cest)
	response, err := service.analyze(context.Background(), entry, departure.UTC())
	if err != nil {
		t.Fatal(err)
	}
	if response.Recommendation != weatherRecommendationRainRisk {
		t.Fatalf("recommendation = %q, want rain_risk for 14:00Z", response.Recommendation)
	}
	if want := time.Date(2026, 10, 24, 14, 0, 0, 0, time.UTC); !response.DepartureAt.Equal(want) {
		t.Fatalf("departureAt = %s, want %s", response.DepartureAt, want)
	}
}

func TestWeatherCacheExpiry(t *testing.T) {
	clock := &fakeClock{t: time.Date(2026, 10, 24, 12, 0, 0, 0, time.UTC)}
	provider := &fakeWeatherProvider{info: testWeatherInfo, forecast: dryForecast}
	service := newWeatherService([]weatherProvider{provider}, time.Minute, clock.now)
	route := testRoute(t, 10000, 1200)
	token, _ := service.register(route)
	body := fmt.Sprintf(`{"routeToken":%q,"departureAt":"2026-10-24T12:00:00Z"}`, token)
	call := func() int {
		request := httptest.NewRequest("POST", "/v1/weather", bytes.NewBufferString(body))
		request.Header.Set("Content-Type", "application/json")
		recorder := httptest.NewRecorder()
		service.serveHTTP(recorder, request)
		return recorder.Code
	}
	if code := call(); code != 200 {
		t.Fatalf("first call = %d", code)
	}
	if code := call(); code != 200 {
		t.Fatalf("second call = %d", code)
	}
	if provider.callCount() != 1 {
		t.Fatalf("provider calls = %d, want 1 (cache hit)", provider.callCount())
	}
	clock.advance(2 * time.Minute)
	if code := call(); code != 200 {
		t.Fatalf("third call = %d", code)
	}
	if provider.callCount() != 2 {
		t.Fatalf("provider calls = %d, want 2 after cache expiry", provider.callCount())
	}
}

func TestWeatherTokenExpiry(t *testing.T) {
	clock := &fakeClock{t: time.Date(2026, 10, 24, 12, 0, 0, 0, time.UTC)}
	provider := &fakeWeatherProvider{info: testWeatherInfo, forecast: dryForecast}
	service := newWeatherService([]weatherProvider{provider}, 15*time.Minute, clock.now)
	route := testRoute(t, 10000, 1200)
	token, _ := service.register(route)
	clock.advance(weatherRouteTokenTTL + time.Minute)
	request := httptest.NewRequest("POST", "/v1/weather", bytes.NewBufferString(fmt.Sprintf(`{"routeToken":%q,"departureAt":"2026-10-24T12:00:00Z"}`, token)))
	request.Header.Set("Content-Type", "application/json")
	recorder := httptest.NewRecorder()
	service.serveHTTP(recorder, request)
	if recorder.Code != 410 {
		t.Fatalf("status = %d, want 410: %s", recorder.Code, recorder.Body.String())
	}
	var failure struct {
		Error APIError `json:"error"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &failure); err != nil || failure.Error.Code != "weather_token_expired" {
		t.Fatalf("unexpected error: %v %s", err, recorder.Body.String())
	}
	if provider.callCount() != 0 {
		t.Fatal("expired token must not call the provider")
	}
}

func TestWeatherSamplingCoverageAndCap(t *testing.T) {
	geometry, points := weatherLine(t, 2_000_000, 200)
	cumulative := cameraCumulative(points)
	samples := sampleRoute(points, cumulative, 400_000, nil, time.Date(2026, 10, 24, 12, 0, 0, 0, time.UTC))
	if len(samples) != weatherMaxSamples {
		t.Fatalf("samples = %d, want %d", len(samples), weatherMaxSamples)
	}
	if samples[0].Meters != 0 || math.Abs(samples[len(samples)-1].Meters-cumulative[len(cumulative)-1]) > 1 {
		t.Fatalf("samples do not cover route: %v .. %v", samples[0].Meters, samples[len(samples)-1].Meters)
	}
	for i := 1; i < len(samples); i++ {
		if samples[i].Meters <= samples[i-1].Meters {
			t.Fatalf("sample positions not increasing at %d", i)
		}
	}
	if geometry == "" {
		t.Fatal("empty geometry")
	}
}

func TestWeatherSamplingMinimumSpacingAndAnchors(t *testing.T) {
	_, points := weatherLine(t, 900, 10)
	cumulative := cameraCumulative(points)
	samples := sampleRoute(points, cumulative, 60, nil, time.Date(2026, 10, 24, 12, 0, 0, 0, time.UTC))
	if len(samples) != 2 || samples[1].Meters <= samples[0].Meters {
		t.Fatalf("short route samples = %+v", samples)
	}
	anchors := []Anchor{{0, 0}, {5, 100}, {10, 200}}
	if got := elapsedAtDistance(cumulative, anchors, 200, cumulative[5]); math.Abs(got-100) > 0.001 {
		t.Fatalf("anchor elapsed = %v, want 100", got)
	}
	if got := elapsedAtDistance(cumulative, nil, 200, cumulative[5]); math.Abs(got-100) > 0.001 {
		t.Fatalf("linear elapsed = %v, want 100", got)
	}
}

func TestWorstForecastMerge(t *testing.T) {
	merged := worstForecast(
		sampleForecast{Available: true, ProbabilityPercent: 20, IntensityMmPerHour: 0.4},
		sampleForecast{Available: true, ProbabilityPercent: 70, IntensityMmPerHour: 0.2},
		sampleForecast{},
	)
	if !merged.Available || merged.ProbabilityPercent != 70 || merged.IntensityMmPerHour != 0.4 {
		t.Fatalf("merged = %+v", merged)
	}
	if unavailable := worstForecast(sampleForecast{}, sampleForecast{}); unavailable.Available {
		t.Fatal("all-missing merge must be unavailable")
	}
}

func TestOpenMeteoBatchingAndAlignment(t *testing.T) {
	const sampleTime = "2026-10-24T12:00"
	var mu sync.Mutex
	var requests, maxCoordinates int
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		count := len(strings.Split(r.URL.Query().Get("latitude"), ","))
		mu.Lock()
		requests++
		if count > maxCoordinates {
			maxCoordinates = count
		}
		mu.Unlock()
		payload := fmt.Sprintf(`{"minutely_15":{"time":[%q],"precipitation":[0.025]},"hourly":{"time":[%q],"precipitation_probability":[40]}}`, sampleTime, sampleTime)
		_, _ = w.Write([]byte("[" + strings.TrimSuffix(strings.Repeat(payload+",", count), ",") + "]"))
	}))
	defer server.Close()
	provider, err := newOpenMeteo(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	provider.Now = func() time.Time { return time.Date(2026, 10, 24, 12, 0, 0, 0, time.UTC) }
	samples := make([]weatherSample, 120)
	at := time.Date(2026, 10, 24, 11, 57, 0, 0, time.UTC)
	for i := range samples {
		samples[i] = weatherSample{Coordinate: Point{52 + float64(i)*0.001, 5}, At: at}
	}
	forecasts, err := provider.Forecast(context.Background(), samples)
	if err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	gotRequests, gotMax := requests, maxCoordinates
	mu.Unlock()
	if gotRequests != 3 || gotMax > openMeteoBatchSize {
		t.Fatalf("requests=%d maxCoordinates=%d", gotRequests, gotMax)
	}
	for _, forecast := range forecasts {
		if !forecast.Available || forecast.ProbabilityPercent != 40 || math.Abs(forecast.IntensityMmPerHour-0.1) > 1e-9 {
			t.Fatalf("unexpected forecast: %+v", forecast)
		}
	}
	if missing := alignForecast(openMeteoPayload{
		Minutely15: openMeteoMinutely{Time: []string{sampleTime}, Precipitation: []*float64{floatPtr(0.1)}},
		Hourly:     openMeteoHourly{Time: []string{sampleTime}, PrecipitationProbability: []*float64{nil}},
	}, at); missing.Available {
		t.Fatal("missing probability must be unavailable")
	}
	if missingPrecipitation := alignForecast(openMeteoPayload{
		Minutely15: openMeteoMinutely{Time: []string{sampleTime}, Precipitation: []*float64{nil}},
		Hourly:     openMeteoHourly{Time: []string{sampleTime}, PrecipitationProbability: []*float64{floatPtr(40)}},
	}, at); missingPrecipitation.Available {
		t.Fatal("missing precipitation must be unavailable")
	}
	if stale := alignForecast(openMeteoPayload{
		Minutely15: openMeteoMinutely{Time: []string{sampleTime}, Precipitation: []*float64{floatPtr(0.1)}},
		Hourly:     openMeteoHourly{Time: []string{sampleTime}, PrecipitationProbability: []*float64{floatPtr(40)}},
	}, at.Add(-time.Hour)); stale.Available {
		t.Fatal("out-of-range time must be unavailable")
	}
}

func floatPtr(value float64) *float64 { return &value }

func TestOpenMeteoUsesIntervalsEndingAtTimestamp(t *testing.T) {
	payload := openMeteoPayload{
		Minutely15: openMeteoMinutely{Time: []string{"2026-10-24T12:00", "2026-10-24T12:15"}, Precipitation: []*float64{floatPtr(0), floatPtr(0.2)}},
		Hourly:     openMeteoHourly{Time: []string{"2026-10-24T12:00", "2026-10-24T13:00"}, PrecipitationProbability: []*float64{floatPtr(0), floatPtr(80)}},
	}
	boundary := time.Date(2026, 10, 24, 12, 0, 0, 0, time.UTC)
	before := alignForecast(payload, boundary)
	after := alignForecast(payload, boundary.Add(time.Second))
	if !before.Available || before.IntensityMmPerHour != 0 || before.ProbabilityPercent != 0 {
		t.Fatalf("boundary must use preceding interval: %+v", before)
	}
	if !after.Available || after.IntensityMmPerHour != 0.8 || after.ProbabilityPercent != 80 {
		t.Fatalf("after boundary must use next interval: %+v", after)
	}
}

func TestWeatherEndpointContract(t *testing.T) {
	clock := &fakeClock{t: time.Date(2026, 10, 24, 13, 50, 0, 0, time.UTC)}
	provider := &fakeWeatherProvider{info: testWeatherInfo, forecast: stormForecast}
	service := newWeatherService([]weatherProvider{provider}, 15*time.Minute, clock.now)
	route := testRoute(t, 10000, 1200)
	handler := handlerWithWeather(&prototypeBase{ordinary: []Route{route}}, nil, service)

	routeRequest, _ := json.Marshal(weatherRouteRequest())
	request := httptest.NewRequest("POST", "/v1/routes", bytes.NewReader(routeRequest))
	request.Header.Set("Content-Type", "application/json")
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)
	if recorder.Code != 200 {
		t.Fatalf("routes status = %d: %s", recorder.Code, recorder.Body.String())
	}
	var routes RouteResponse
	if err := json.Unmarshal(recorder.Body.Bytes(), &routes); err != nil {
		t.Fatal(err)
	}
	token := routes.Routes[0].WeatherToken
	if !validWeatherToken(token) || routes.Routes[0].WeatherExpiresAt == nil {
		t.Fatalf("missing route weather token: %+v", routes.Routes[0])
	}

	body := fmt.Sprintf(`{"routeToken":%q,"departureAt":"2026-10-24T13:55:00Z"}`, token)
	weatherRequest := httptest.NewRequest("POST", "/v1/weather", bytes.NewBufferString(body))
	weatherRequest.Header.Set("Content-Type", "application/json")
	weatherRecorder := httptest.NewRecorder()
	handler.ServeHTTP(weatherRecorder, weatherRequest)
	if weatherRecorder.Code != 200 {
		t.Fatalf("weather status = %d: %s", weatherRecorder.Code, weatherRecorder.Body.String())
	}
	var response WeatherResponse
	if err := json.Unmarshal(weatherRecorder.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if response.RouteToken != token || response.Provider.ID != "open-meteo" || response.Recommendation != weatherRecommendationRainRisk {
		t.Fatalf("unexpected response: %+v", response)
	}
	if response.Summary == nil || len(response.Segments) == 0 || response.Warnings == nil {
		t.Fatalf("unexpected response payload: %+v", response)
	}

	for _, invalid := range []string{
		`{}`,
		fmt.Sprintf(`{"routeToken":%q}`, token),
		fmt.Sprintf(`{"routeToken":%q,"departureAt":"not-a-time"}`, token),
		fmt.Sprintf(`{"routeToken":%q,"departureAt":"2026-10-24T13:55:00Z","geometry":"resend"}`, token),
	} {
		req := httptest.NewRequest("POST", "/v1/weather", bytes.NewBufferString(invalid))
		req.Header.Set("Content-Type", "application/json")
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		if rec.Code != 400 {
			t.Fatalf("invalid body %s => %d: %s", invalid, rec.Code, rec.Body.String())
		}
	}

	unknown := httptest.NewRequest("POST", "/v1/weather", bytes.NewBufferString(`{"routeToken":"0123456789abcdef0123456789abcdef","departureAt":"2026-10-24T13:55:00Z"}`))
	unknown.Header.Set("Content-Type", "application/json")
	unknownRecorder := httptest.NewRecorder()
	handler.ServeHTTP(unknownRecorder, unknown)
	if unknownRecorder.Code != 410 {
		t.Fatalf("unknown token status = %d", unknownRecorder.Code)
	}

	capabilityRequest := httptest.NewRequest("GET", "/v1/capabilities", nil)
	capabilityRecorder := httptest.NewRecorder()
	handler.ServeHTTP(capabilityRecorder, capabilityRequest)
	var capabilities map[string]any
	if err := json.Unmarshal(capabilityRecorder.Body.Bytes(), &capabilities); err != nil {
		t.Fatal(err)
	}
	weather, ok := capabilities["weather"].(map[string]any)
	if !ok {
		t.Fatalf("missing weather capabilities: %s", capabilityRecorder.Body.String())
	}
	if weather["provider"] != "open-meteo" || weather["license"] != "CC BY 4.0" ||
		weather["attribution"] != "Weather data by Open-Meteo.com" ||
		weather["coverage"] != "Worldwide; 15-minute precipitation in the Netherlands/Central Europe" ||
		weather["routeTokenTTLSeconds"] != float64(900) || weather["cacheTTLSeconds"] != float64(900) {
		t.Fatalf("unexpected weather capabilities: %+v", weather)
	}
	sampling := weather["sampling"].(map[string]any)
	if sampling["distanceMeters"] != float64(2000) || sampling["intervalSeconds"] != float64(300) || sampling["maxSamples"] != float64(400) {
		t.Fatalf("unexpected sampling capabilities: %+v", sampling)
	}
	rainRisk := weather["rainRisk"].(map[string]any)
	if rainRisk["probabilityPercent"] != float64(30) || rainRisk["intensityMmPerHour"] != 0.1 {
		t.Fatalf("unexpected rain risk capabilities: %+v", rainRisk)
	}
}

func TestWeatherUnavailableAndRoutingIsolation(t *testing.T) {
	clock := &fakeClock{t: time.Date(2026, 10, 24, 12, 0, 0, 0, time.UTC)}
	provider := &fakeWeatherProvider{info: testWeatherInfo, forecast: dryForecast, err: apiError("weather_unavailable")}
	service := newWeatherService([]weatherProvider{provider}, 15*time.Minute, clock.now)
	route := testRoute(t, 10000, 1200)
	handler := handlerWithWeather(&prototypeBase{ordinary: []Route{route}}, nil, service)
	routeRequest, _ := json.Marshal(weatherRouteRequest())
	request := httptest.NewRequest("POST", "/v1/routes", bytes.NewReader(routeRequest))
	request.Header.Set("Content-Type", "application/json")
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)
	if recorder.Code != 200 {
		t.Fatalf("weather failure affected routing: %d %s", recorder.Code, recorder.Body.String())
	}
	var routes RouteResponse
	if err := json.Unmarshal(recorder.Body.Bytes(), &routes); err != nil {
		t.Fatal(err)
	}
	token := routes.Routes[0].WeatherToken
	if token == "" {
		t.Fatal("route token missing while weather provider is down")
	}
	body := fmt.Sprintf(`{"routeToken":%q,"departureAt":"2026-10-24T12:00:00Z"}`, token)
	weatherRequest := httptest.NewRequest("POST", "/v1/weather", bytes.NewBufferString(body))
	weatherRequest.Header.Set("Content-Type", "application/json")
	weatherRecorder := httptest.NewRecorder()
	handler.ServeHTTP(weatherRecorder, weatherRequest)
	if weatherRecorder.Code != 503 {
		t.Fatalf("weather status = %d, want 503: %s", weatherRecorder.Code, weatherRecorder.Body.String())
	}
	ready := httptest.NewRecorder()
	handler.ServeHTTP(ready, httptest.NewRequest("GET", "/readyz", nil))
	if ready.Code != 200 {
		t.Fatalf("readiness affected by weather: %d", ready.Code)
	}
}

func TestWeatherNoGeometryResendToProvider(t *testing.T) {
	clock := &fakeClock{t: time.Date(2026, 10, 24, 12, 0, 0, 0, time.UTC)}
	provider := &fakeWeatherProvider{info: testWeatherInfo, forecast: dryForecast}
	service, route, _ := testWeatherService(t, provider, clock, 15*time.Minute, 10000, 1200)
	token, _ := service.register(route)
	body := fmt.Sprintf(`{"routeToken":%q,"departureAt":"2026-10-24T12:00:00Z"}`, token)
	request := httptest.NewRequest("POST", "/v1/weather", bytes.NewBufferString(body))
	request.Header.Set("Content-Type", "application/json")
	recorder := httptest.NewRecorder()
	service.serveHTTP(recorder, request)
	if recorder.Code != 200 {
		t.Fatalf("status = %d: %s", recorder.Code, recorder.Body.String())
	}
	provider.mu.Lock()
	batches := append([]int(nil), provider.batches...)
	provider.mu.Unlock()
	if len(batches) != 1 || batches[0] > weatherMaxSamples {
		t.Fatalf("provider batches = %v", batches)
	}
	if strings.Contains(body, "geometry") || strings.Contains(body, "polyline") {
		t.Fatal("weather request resent route geometry")
	}
}

func weatherRouteRequest() RouteRequest {
	return RouteRequest{
		Waypoints:    []WaypointRequest{{Coordinate: Point{52, 5}, Kind: "stop"}, {Coordinate: Point{52.1, 5.1}, Kind: "stop"}},
		Profile:      "car",
		Objective:    "fastest",
		Preferences:  Preferences{"neutral", "neutral", "neutral"},
		Alternatives: 0,
		Language:     "en-US",
	}
}
