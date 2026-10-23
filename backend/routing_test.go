package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"math"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

func request() RouteRequest {
	return RouteRequest{Waypoints: []WaypointRequest{{Coordinate: Point{52.09, 5.12}, Kind: "stop"}, {Coordinate: Point{52.091, 5.1216}, Kind: "stop"}}, Profile: "car", Objective: "fastest", Preferences: Preferences{"neutral", "neutral", "neutral"}, Alternatives: 2, Language: "en-US"}
}
func fixture(t *testing.T) vhResponse {
	t.Helper()
	b, e := os.ReadFile("testdata/valhalla.json")
	if e != nil {
		t.Fatal(e)
	}
	var v vhResponse
	if e = json.Unmarshal(b, &v); e != nil {
		t.Fatal(e)
	}
	return v
}
func assertCode(t *testing.T, err error, code string) {
	t.Helper()
	var e *APIError
	if !errors.As(err, &e) || e.Code != code {
		t.Fatalf("got %v, want %s", err, code)
	}
}

func TestSharedContract(t *testing.T) {
	b, e := os.ReadFile("../ios/RoadScout/Resources/route-response.json")
	if e != nil {
		t.Fatal(e)
	}
	var shared RouteResponse
	if e = json.Unmarshal(b, &shared); e != nil {
		t.Fatal(e)
	}
	route, e := normalize(fixture(t).Trip, request())
	if e != nil {
		t.Fatal(e)
	}
	expected := shared.Routes[0]
	if route.Geometry != expected.Geometry || route.Summary != expected.Summary || len(route.Legs[0].Maneuvers) != 3 {
		t.Fatalf("contract mismatch: %+v", route)
	}
	if route.Legs[0].Maneuvers[1].Type != "turn" || route.Legs[0].Maneuvers[1].Modifier != "right" {
		t.Fatal("maneuver mapping")
	}
	if route.Timing.Anchors[len(route.Timing.Anchors)-1].Elapsed != 28 {
		t.Fatal("timing total")
	}
}
func TestMultiLegRemappingAndUnits(t *testing.T) {
	trip := fixture(t).Trip
	trip.Legs = append(trip.Legs, trip.Legs[0])
	p, _ := decodePolyline(trip.Legs[0].Shape)
	for i := range p {
		p[i].Latitude += .001
		p[i].Longitude += .0016
	}
	trip.Legs[1].Shape = encodePolyline(p)
	trip.Summary.Length *= 2
	trip.Summary.Time *= 2
	r := request()
	r.Waypoints = append(r.Waypoints, WaypointRequest{Coordinate: p[len(p)-1], Kind: "stop"})
	route, e := normalize(trip, r)
	if e != nil {
		t.Fatal(e)
	}
	if route.Geometry.Count != 9 || route.Legs[1].Begin != 4 || route.Legs[1].Maneuvers[1].Begin != 6 || len(route.Waypoints) != 3 {
		t.Fatal("incorrect global indices")
	}
	trip.Units = "miles"
	route, e = normalize(trip, r)
	if e != nil {
		t.Fatal(e)
	}
	if math.Abs(route.Summary.Distance-.44*1609.344) > 1e-6 {
		t.Fatal("miles conversion")
	}
}
func TestMalformedRoutes(t *testing.T) {
	for _, test := range []struct {
		name   string
		mutate func(*vhTrip)
	}{
		{"bad shape", func(v *vhTrip) { v.Legs[0].Shape = "_" }},
		{"indices", func(v *vhTrip) { v.Legs[0].Maneuvers[1].End = 999 }},
		{"reversed", func(v *vhTrip) { v.Legs[0].Maneuvers[1].Begin = 4; v.Legs[0].Maneuvers[1].End = 2 }},
		{"time", func(v *vhTrip) { v.Summary.Time = -1 }},
		{"units", func(v *vhTrip) { v.Units = "feet" }},
		{"discontinuous legs", func(v *vhTrip) { v.Legs = append(v.Legs, v.Legs[0]) }},
		{"inconsistent totals", func(v *vhTrip) { v.Summary.Time = 999 }},
	} {
		t.Run(test.name, func(t *testing.T) {
			v := fixture(t).Trip
			test.mutate(&v)
			_, e := normalize(v, request())
			assertCode(t, e, "invalid_upstream_response")
		})
	}
}
func TestUnknownManeuverAndZeroDuration(t *testing.T) {
	v := fixture(t).Trip
	v.Legs[0].Maneuvers[1].Type = 999
	v.Summary.Time = 0
	v.Legs[0].Summary.Time = 0
	for i := range v.Legs[0].Maneuvers {
		v.Legs[0].Maneuvers[i].Time = 0
	}
	r, e := normalize(v, request())
	if e != nil {
		t.Fatal(e)
	}
	if r.Legs[0].Maneuvers[1].Type != "unknown" {
		t.Fatal("unknown type")
	}
}
func TestValhallaRequestAndAlternatives(t *testing.T) {
	v := fixture(t)
	v.Alternates = append(v.Alternates, struct {
		Trip vhTrip `json:"trip"`
	}{v.Trip})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/route" || r.Method != "POST" {
			t.Error("wrong endpoint")
		}
		var payload map[string]any
		_ = json.NewDecoder(r.Body).Decode(&payload)
		auto := payload["costing_options"].(map[string]any)["auto"].(map[string]any)
		if auto["use_tolls"] != float64(0) || auto["use_highways"] != .5 || payload["units"] != "kilometers" {
			t.Error("wrong options")
		}
		_ = json.NewEncoder(w).Encode(v)
	}))
	defer server.Close()
	p, _ := newValhalla(server.URL)
	req := request()
	req.Preferences.Tolls = "avoid"
	routes, _, e := p.Routes(context.Background(), req)
	if e != nil || len(routes) != 2 {
		t.Fatalf("%v %d", e, len(routes))
	}
}
func TestUpstreamErrors(t *testing.T) {
	for _, test := range []struct {
		body   string
		status int
		code   string
	}{{`{"error_code":442}`, 400, "no_route"}, {`{"error_code":171}`, 400, "cannot_snap"}, {`unavailable`, 503, "upstream_unavailable"}, {`{}`, 200, "invalid_upstream_response"}} {
		t.Run(test.code, func(t *testing.T) {
			s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(test.status)
				_, _ = w.Write([]byte(test.body))
			}))
			defer s.Close()
			v, _ := newValhalla(s.URL)
			_, _, e := v.Routes(context.Background(), request())
			assertCode(t, e, test.code)
		})
	}
}
func TestTimeoutAndCancellation(t *testing.T) {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-r.Context().Done():
		case <-time.After(100 * time.Millisecond):
		}
	}))
	defer s.Close()
	v, _ := newValhalla(s.URL)
	v.Client.Timeout = 20 * time.Millisecond
	_, _, e := v.Routes(context.Background(), request())
	assertCode(t, e, "upstream_timeout")
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, _, e = v.Routes(ctx, request())
	if !errors.Is(e, context.Canceled) {
		t.Fatalf("cancellation: %v", e)
	}
}

func TestTimeoutReadingResponseBody(t *testing.T) {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(200)
		w.(http.Flusher).Flush()
		select {
		case <-r.Context().Done():
		case <-time.After(100 * time.Millisecond):
		}
	}))
	defer s.Close()
	v, _ := newValhalla(s.URL)
	v.Client.Timeout = 20 * time.Millisecond
	_, _, err := v.Routes(context.Background(), request())
	assertCode(t, err, "upstream_timeout")
}
func TestHTTPContract(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/status" {
			_, _ = w.Write([]byte(`{}`))
			return
		}
		_ = json.NewEncoder(w).Encode(fixture(t))
	}))
	defer upstream.Close()
	v, _ := newValhalla(upstream.URL)
	h := handler(v)
	body, _ := json.Marshal(request())
	for _, tc := range []struct {
		path, method, body string
		status             int
	}{{"/v1/routes", "POST", string(body), 200}, {"/v1/routes", "POST", `{}`, 400}, {"/v1/routes", "POST", string(body) + `{}`, 400}, {"/v1/routes", "POST", strings.Replace(string(body), `"latitude":52.09`, `"latitude":999`, 1), 400}, {"/v1/routes", "POST", strings.Replace(string(body), `"coordinate":{"latitude":52.09,"longitude":5.12},`, "", 1), 400}, {"/v1/routes", "POST", strings.Replace(string(body), `"neutral"`, `"exclude"`, 1), 400}, {"/readyz", "GET", "", 200}, {"/healthz", "GET", "", 200}, {"/v1/capabilities", "GET", "", 200}} {
		r := httptest.NewRequest(tc.method, tc.path, bytes.NewBufferString(tc.body))
		r.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != tc.status {
			t.Errorf("%s %s: %d %s", tc.method, tc.path, w.Code, w.Body.String())
		}
	}
}
func FuzzPolyline(f *testing.F) {
	f.Add("_hijbB__owHg^?g^??_q@?_q@")
	f.Add("_")
	f.Fuzz(func(t *testing.T, s string) {
		p, e := decodePolyline(s)
		if e == nil {
			encoded := encodePolyline(p)
			again, e := decodePolyline(encoded)
			if e != nil || len(again) != len(p) {
				t.Fatal("roundtrip")
			}
		}
	})
}
