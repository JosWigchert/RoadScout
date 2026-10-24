package main

import (
	"bytes"
	"context"
	"encoding/json"
	"math"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
)

func prototypeRoute(id string, curve bool, spacing float64, seconds float64) Route {
	points := []Point{}
	for x := 0.0; x <= 2000; x += spacing {
		y := 0.0
		if curve {
			y = 80 * math.Sin(2*math.Pi*x/400)
		}
		points = append(points, Point{52 + y/111_000, 5 + x/(111_000*math.Cos(52*math.Pi/180))})
	}
	meters := 0.0
	for i := 1; i < len(points); i++ {
		meters += distance(points[i-1], points[i])
	}
	return Route{ID: id, Geometry: Geometry{"polyline6", 2, len(points), encodePolyline(points)}, Summary: Summary{meters, seconds},
		Legs: []Leg{{Begin: 0, End: len(points) - 1, Maneuvers: []Maneuver{{Type: "depart", Begin: 0, End: len(points) - 1}}}}}
}
func prototypeAttributes(route Route, class string) roadAttributes {
	density := 3
	return roadAttributes{Shape: route.Geometry.Data, Edges: []roadEdge{{Begin: 0, End: route.Geometry.Count - 1,
		Class: class, Surface: "paved", Use: "road", Density: &density}}}
}

type prototypeBase struct {
	ordinary, country []Route
	requests          []RouteRequest
}

func (p *prototypeBase) Ready(context.Context) error { return nil }
func (p *prototypeBase) Routes(_ context.Context, request RouteRequest) ([]Route, []Warning, error) {
	p.requests = append(p.requests, request)
	if request.Preferences.Motorways == "avoid" {
		return p.country, nil, nil
	}
	return p.ordinary, nil, nil
}

type prototypeAttributesProvider struct {
	values map[string]roadAttributes
	calls  atomic.Int64
}

func (p *prototypeAttributesProvider) attributesFor(_ context.Context, route Route) (roadAttributes, error) {
	p.calls.Add(1)
	if value, ok := p.values[route.Geometry.Data]; ok {
		return value, nil
	}
	return roadAttributes{}, apiError("upstream_unavailable")
}

func TestPrototypeBendsAreDistanceBasedAndExcludeIneligibleRoads(t *testing.T) {
	straight := prototypeRoute("straight", false, 10, 100)
	curve := prototypeRoute("curve", true, 5, 120)
	a, err := analyzeRoadRoute(straight, prototypeAttributes(straight, "secondary"))
	if err != nil || a.bends != 0 {
		t.Fatalf("straight: %+v %v", a, err)
	}
	b, err := analyzeRoadRoute(curve, prototypeAttributes(curve, "secondary"))
	if err != nil || b.bends < 6 || b.density <= a.density {
		t.Fatalf("curves: %+v %v", b, err)
	}
	coarse := prototypeRoute("coarse", true, 10, 120)
	c, err := analyzeRoadRoute(coarse, prototypeAttributes(coarse, "secondary"))
	if err != nil || math.Abs(float64(c.bends-b.bends)) > 1 {
		t.Fatalf("sampling changed bends: %+v vs %+v", b, c)
	}
	for _, class := range []string{"residential", "motorway", "service_other"} {
		m, e := analyzeRoadRoute(curve, prototypeAttributes(curve, class))
		if e != nil || m.bends != 0 || m.countryside != 0 {
			t.Fatalf("ineligible %s: %+v %v", class, m, e)
		}
	}
	for _, mutation := range []func(*roadAttributes){
		func(a *roadAttributes) { a.Edges[0].Surface = "gravel" },
		func(a *roadAttributes) { n := 15; a.Edges[0].Density = &n },
		func(a *roadAttributes) { a.Edges[0].Use = "parking_aisle" },
	} {
		attrs := prototypeAttributes(curve, "secondary")
		mutation(&attrs)
		m, e := analyzeRoadRoute(curve, attrs)
		if e != nil || m.bends != 0 || m.countryside != 0 {
			t.Fatalf("excluded attributes: %+v %v", m, e)
		}
	}
}

func TestPrototypeDoesNotRewardJunctionsRoundaboutsOrUTurns(t *testing.T) {
	route := prototypeRoute("junctions", true, 10, 120)
	// Cover every bend with a supplied junction maneuver; turning instructions are not curves.
	route.Legs[0].Maneuvers = nil
	for i := 0; i < route.Geometry.Count; i += 2 {
		route.Legs[0].Maneuvers = append(route.Legs[0].Maneuvers, Maneuver{Type: "turn", Begin: i, End: i})
	}
	m, e := analyzeRoadRoute(route, prototypeAttributes(route, "secondary"))
	if e != nil || m.bends != 0 {
		t.Fatalf("junctions: %+v %v", m, e)
	}
	route.Legs[0].Maneuvers = []Maneuver{{Type: "roundabout_enter", Begin: 0, End: route.Geometry.Count - 1}}
	m, e = analyzeRoadRoute(route, prototypeAttributes(route, "secondary"))
	if e != nil || m.bends != 0 {
		t.Fatalf("roundabout: %+v %v", m, e)
	}
	points := []Point{}
	for i := 0; i <= 60; i++ {
		angle := math.Pi * float64(i) / 60
		points = append(points, Point{52 + 50*math.Sin(angle)/111_000, 5 + 50*math.Cos(angle)/(111_000*math.Cos(52*math.Pi/180))})
	}
	route.Geometry = Geometry{"polyline6", 2, len(points), encodePolyline(points)}
	route.Legs = []Leg{{Begin: 0, End: len(points) - 1}}
	m, e = analyzeRoadRoute(route, prototypeAttributes(route, "secondary"))
	if e != nil || m.bends != 0 {
		t.Fatalf("u-turn geometry: %+v %v", m, e)
	}
}

func TestPrototypeBudgetDeduplicationAndHonestFallback(t *testing.T) {
	fast := prototypeRoute("fast", false, 10, 100)
	curve := prototypeRoute("curve", true, 10, 120)
	base := &prototypeBase{ordinary: []Route{fast}, country: []Route{curve, curve}}
	attrs := &prototypeAttributesProvider{values: map[string]roadAttributes{fast.Geometry.Data: prototypeAttributes(fast, "motorway"), curve.Geometry.Data: prototypeAttributes(curve, "secondary")}}
	router := &experimentalRouter{base: base, attributes: attrs}
	input := request()
	input.Objective = "more_corners"
	routes, warnings, err := router.Routes(context.Background(), input)
	if err != nil || len(routes) != 2 || routes[0].ID != "curve" || routes[0].Objective != "more_corners" || routes[0].Experiment.Status != "improved" || len(warnings) != 0 {
		t.Fatalf("selection: %+v %+v %v", routes, warnings, err)
	}
	if attrs.calls.Load() != 2 {
		t.Fatal("duplicate geometry analyzed")
	}
	if len(base.requests) != 2 || base.requests[1].Profile != "car" || base.requests[1].Objective != "fastest" || base.requests[1].Preferences.Motorways != "avoid" {
		t.Fatal("costing/access changed incorrectly")
	}
	budget := 15
	input.MaxExtraDurationPercent = &budget
	routes, warnings, err = router.Routes(context.Background(), input)
	if err != nil || routes[0].ID != "fast" || routes[0].Objective != "fastest" || routes[0].Experiment.Status != "no_improvement" || len(warnings) == 0 {
		t.Fatalf("budget fallback: %+v %+v %v", routes, warnings, err)
	}
	input.Objective = "scenic"
	input.MaxExtraDurationPercent = nil
	input.Alternatives = 0
	routes, _, err = router.Routes(context.Background(), input)
	if err != nil || len(routes) != 1 || routes[0].Objective != "scenic" || routes[0].Experiment.CountrysideShare < 0.99 {
		t.Fatalf("scenic: %+v %v", routes, err)
	}
	delete(attrs.values, fast.Geometry.Data)
	routes, warnings, err = router.Routes(context.Background(), input)
	if err != nil || routes[0].Objective != "fastest" || routes[0].Experiment.Status != "metadata_unavailable" || len(warnings) == 0 {
		t.Fatal("metadata fallback was mislabeled")
	}
}

func TestFastestDoesNotRunExperimentalAnalysisAndCapabilitiesAreOptIn(t *testing.T) {
	fast := prototypeRoute("fast", false, 10, 100)
	base := &prototypeBase{ordinary: []Route{fast}}
	attrs := &prototypeAttributesProvider{}
	router := &experimentalRouter{base: base, attributes: attrs}
	if _, _, err := router.Routes(context.Background(), request()); err != nil || attrs.calls.Load() != 0 || len(base.requests) != 1 {
		t.Fatal("Fastest changed")
	}
	for _, enabled := range []bool{false, true} {
		var provider RoutingProvider = base
		if enabled {
			provider = router
		}
		w := httptest.NewRecorder()
		handler(provider).ServeHTTP(w, httptest.NewRequest("GET", "/v1/capabilities", nil))
		var value struct {
			Objectives []string `json:"objectives"`
		}
		_ = json.Unmarshal(w.Body.Bytes(), &value)
		want := 1
		if enabled {
			want = 3
		}
		if len(value.Objectives) != want {
			t.Fatal("incorrect advertised objectives")
		}
		input := request()
		input.Objective = "scenic"
		err := input.validateFor(routingObjectives(provider))
		if enabled && err != nil {
			t.Fatal(err)
		}
		if !enabled {
			assertCode(t, err, "unsupported_option")
		}
	}
	input := request()
	input.Objective = "scenic"
	budget := -1
	input.MaxExtraDurationPercent = &budget
	assertCode(t, input.validateFor(routingObjectives(router)), "invalid_request")
}

func TestScenicAndCornersRankDifferentQualities(t *testing.T) {
	fast := prototypeRoute("fast", false, 10, 100)
	rural := prototypeRoute("rural-straight", false, 20, 110)
	curvy := prototypeRoute("rural-curvy", true, 10, 125)
	base := &prototypeBase{ordinary: []Route{fast}, country: []Route{rural, curvy}}
	attributes := &prototypeAttributesProvider{values: map[string]roadAttributes{
		fast.Geometry.Data: prototypeAttributes(fast, "motorway"), rural.Geometry.Data: prototypeAttributes(rural, "secondary"),
		curvy.Geometry.Data: prototypeAttributes(curvy, "secondary"),
	}}
	router := &experimentalRouter{base: base, attributes: attributes}
	input := request()
	input.Objective = "scenic"
	routes, _, err := router.Routes(context.Background(), input)
	if err != nil || routes[0].ID != "rural-straight" {
		t.Fatalf("Scenic did not prefer equivalent countryside share with less detour: %+v %v", routes, err)
	}
	input.Objective = "more_corners"
	routes, _, err = router.Routes(context.Background(), input)
	if err != nil || routes[0].ID != "rural-curvy" {
		t.Fatalf("Corners did not prefer actual bends: %+v %v", routes, err)
	}
}

func TestTraceAttributesUsesMatchingShapeAndBoundedMetadata(t *testing.T) {
	route := prototypeRoute("trace", true, 10, 100)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/trace_attributes" {
			t.Error("wrong path")
		}
		var payload map[string]any
		_ = json.NewDecoder(r.Body).Decode(&payload)
		if payload["costing"] != "auto" || payload["shape_match"] != "edge_walk" || payload["encoded_polyline"] != route.Geometry.Data {
			t.Error("unsafe or wrong trace request")
		}
		_ = json.NewEncoder(w).Encode(prototypeAttributes(route, "secondary"))
	}))
	defer server.Close()
	v, _ := newValhalla(server.URL)
	a, err := v.attributesFor(context.Background(), route)
	if err != nil || a.Shape != route.Geometry.Data {
		t.Fatal(err)
	}
	a.Edges[0].Density = nil
	if _, err = analyzeRoadRoute(route, a); err == nil {
		t.Fatal("missing metadata accepted")
	}
	// Invalid prototype values must be rejected by the public handler before graph work.
	input := request()
	input.Objective = "scenic"
	budget := 101
	input.MaxExtraDurationPercent = &budget
	data, _ := json.Marshal(input)
	w := httptest.NewRecorder()
	req := httptest.NewRequest("POST", "/v1/routes", bytes.NewReader(data))
	req.Header.Set("Content-Type", "application/json")
	handler(&experimentalRouter{base: &prototypeBase{}, attributes: v}).ServeHTTP(w, req)
	if w.Code != 400 {
		t.Fatalf("got %d", w.Code)
	}
}

func TestCapabilitiesAdvertiseServerDrivenRoutingCatalog(t *testing.T) {
	base := &prototypeBase{}
	enabled := &experimentalRouter{base: base, attributes: &prototypeAttributesProvider{}}
	for _, test := range []struct {
		name         string
		provider     RoutingProvider
		wantOptions  int
		experimental bool
	}{
		{"disabled", base, 1, false},
		{"enabled", enabled, 3, true},
	} {
		t.Run(test.name, func(t *testing.T) {
			recorder := httptest.NewRecorder()
			handler(test.provider).ServeHTTP(recorder, httptest.NewRequest("GET", "/v1/capabilities", nil))
			var body struct {
				Objectives     []string        `json:"objectives"`
				RoutingOptions []RoutingOption `json:"routingOptions"`
				DetourOptions  []int           `json:"detourOptions"`
			}
			if err := json.Unmarshal(recorder.Body.Bytes(), &body); err != nil {
				t.Fatal(err)
			}
			if len(body.Objectives) != test.wantOptions || len(body.RoutingOptions) != test.wantOptions {
				t.Fatalf("unexpected catalog: %+v", body)
			}
			if body.RoutingOptions[0].ID != "fastest" || body.RoutingOptions[0].Title != "Fastest" || body.RoutingOptions[0].Experimental {
				t.Fatalf("fastest option must be first and non-experimental: %+v", body.RoutingOptions[0])
			}
			if test.experimental {
				if !body.RoutingOptions[1].Experimental || body.RoutingOptions[1].Title == "" {
					t.Fatalf("experimental option metadata missing: %+v", body.RoutingOptions[1])
				}
				if len(body.RoutingOptions[1].DetourOptions) != len(defaultDetourOptions) {
					t.Fatalf("detour options not advertised: %+v", body.RoutingOptions[1])
				}
				if len(body.DetourOptions) != len(defaultDetourOptions) {
					t.Fatalf("aggregate detour options not advertised: %+v", body.DetourOptions)
				}
			} else if len(body.DetourOptions) != 0 {
				t.Fatalf("disabled experiments should advertise no detour budgets: %+v", body.DetourOptions)
			}
		})
	}
}
