package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func cameraNode(id int64, lat, lon float64, tags map[string]string) osmElement {
	return osmElement{Type: "node", ID: id, Lat: &lat, Lon: &lon, Tags: tags}
}
func cameraElements() []osmElement {
	return []osmElement{
		cameraNode(1, 52, 5, map[string]string{"highway": "speed_camera", "direction": "270", "maxspeed": "80"}),
		cameraNode(2, 52.001, 5.001, nil), cameraNode(3, 52.002, 5.001, nil), cameraNode(4, 52.003, 5, nil),
		cameraNode(5, 52.00001, 5.00001, map[string]string{"highway": "speed_camera"}),
		{Type: "way", ID: 10, Nodes: []int64{1, 2}, Tags: map[string]string{"highway": "primary", "oneway": "yes"}},
		{Type: "way", ID: 11, Nodes: []int64{4, 3, 2}, Tags: map[string]string{"highway": "primary", "oneway": "-1"}},
		{Type: "relation", ID: 20, Tags: map[string]string{"type": "enforcement", "enforcement": "average_speed", "maxspeed": "100"}, Members: []osmMember{{"way", 11, ""}, {"node", 4, "to"}, {"node", 1, "from"}, {"way", 10, ""}, {"node", 5, "device"}}},
		{Type: "relation", ID: 21, Tags: map[string]string{"type": "enforcement", "enforcement": "traffic_signals"}, Members: []osmMember{{"node", 1, "device"}}},
		{Type: "relation", ID: 22, Tags: map[string]string{"type": "enforcement", "enforcement": "maxspeed"}, Members: []osmMember{{"node", 1, "device"}}},
		{Type: "relation", ID: 23, Tags: map[string]string{"type": "enforcement", "enforcement": "average_speed"}, Members: []osmMember{{"node", 1, "from"}}},
	}
}
func cameraDocument(elements []osmElement, remark string) []byte {
	counts := map[string]string{}
	for _, kind := range []string{"node", "way", "relation"} {
		n := 0
		for _, e := range elements {
			if e.Type == kind {
				n++
			}
		}
		counts[kind+"s"] = fmt.Sprint(n)
	}
	counts["total"] = fmt.Sprint(len(elements))
	all := append(append([]osmElement{}, elements...), osmElement{Type: "count", Tags: counts})
	b, _ := json.Marshal(map[string]any{"osm3s": map[string]string{"timestamp_osm_base": "2026-10-24T18:28:52Z"}, "elements": all, "remark": remark})
	return b
}
func TestCameraImporterIdentityDirectionAndZoneGraph(t *testing.T) {
	s, err := importCameras(cameraDocument(cameraElements(), ""))
	if err != nil {
		t.Fatal(err)
	}
	if len(s.Cameras) != 2 || len(s.Zones) != 2 || s.Dataset.IncompleteZoneCount != 1 {
		t.Fatalf("wrong counts: %+v", s)
	}
	if s.Cameras[0].ID != "osm:node:1" || s.Cameras[0].Kind != "combined" || s.Cameras[0].DirectionDegrees != nil || s.Cameras[0].Association != "on_way" {
		t.Fatalf("camera facing or identity mishandled: %+v", s.Cameras[0])
	}
	if len(s.Cameras[0].SourceIDs) != 3 || s.Cameras[1].Kind != "average_speed" {
		t.Fatal("relation device identity normalization")
	}
	z := s.Zones[0]
	if !z.GeometryVerified || len(z.Geometry) != 4 || z.Geometry[0].Latitude != 52 || z.Geometry[3].Latitude != 52.003 || len(z.RoadWayIDs) != 2 {
		t.Fatalf("zone not ordered: %+v", z)
	}
	if z.DirectionDegrees == nil || *z.DirectionDegrees < 0 || *z.DirectionDegrees >= 360 {
		t.Fatal("unnormalized travel direction")
	}
	if s.Zones[1].GeometryVerified || len(s.Zones[1].Geometry) != 0 || s.Zones[1].Start == nil {
		t.Fatal("incomplete zone must retain marker without connector")
	}
}

func TestCameraImporterConflictingEnforcedDirections(t *testing.T) {
	e := cameraElements()
	delete(e[5].Tags, "oneway")
	delete(e[6].Tags, "oneway")
	reverse := e[7]
	reverse.ID = 24
	reverse.Members = []osmMember{{"way", 10, ""}, {"way", 11, ""}, {"node", 4, "from"}, {"node", 1, "to"}, {"node", 5, "device"}}
	e = append(e, reverse)
	s, err := importCameras(cameraDocument(e, ""))
	if err != nil {
		t.Fatal(err)
	}
	if s.Cameras[1].DirectionDegrees != nil || s.Cameras[1].Association != "relation" || len(s.Cameras[1].RoadGeometry) != 4 {
		t.Fatal("opposing relations must not pick an arbitrary enforced direction", s.Cameras[1])
	}
}
func TestCameraZoneRejectsDisconnectedAmbiguousAndWrongDirection(t *testing.T) {
	for _, scenario := range []string{"disconnected", "ambiguous", "wrong_direction", "role_conflict", "multiple_entries"} {
		t.Run(scenario, func(t *testing.T) {
			e := cameraElements()
			switch scenario {
			case "disconnected":
				e[6].Nodes = []int64{4, 3}
			case "ambiguous":
				e = append(e, osmElement{Type: "way", ID: 12, Nodes: []int64{1, 4}, Tags: map[string]string{"highway": "primary"}})
			case "wrong_direction":
				e[6].Tags["oneway"] = "yes"
			case "role_conflict":
				e[7].Members[3].Role = "backward"
			case "multiple_entries":
				e[7].Members = append(e[7].Members, osmMember{"node", 2, "from"})
			}
			s, err := importCameras(cameraDocument(e, ""))
			if err != nil {
				t.Fatal(err)
			}
			if s.Zones[0].GeometryVerified || len(s.Zones[0].Geometry) != 0 {
				t.Fatal("unproven geometry must not be enforced")
			}
		})
	}
}

type fixtureCameraFetcher struct {
	data []byte
	err  error
}

func (f fixtureCameraFetcher) fetch(context.Context) ([]byte, error) { return f.data, f.err }
func TestCameraStoreAtomicSyncAndNoChange(t *testing.T) {
	dir := t.TempDir()
	s, err := newCameraStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	good := cameraDocument(cameraElements(), "")
	fetch := fixtureCameraFetcher{data: good}
	if err = s.sync(context.Background(), fetch, now); err != nil {
		t.Fatal(err)
	}
	before := s.read()
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; i < 500; i++ {
			snapshot := s.read()
			if len(snapshot.Cameras) != 2 {
				t.Error("partial publication")
			}
		}
	}()
	later := now.Add(time.Hour)
	if err = s.sync(context.Background(), fetch, later); err != nil {
		t.Fatal(err)
	}
	wg.Wait()
	after := s.read()
	if before.Dataset.Version != after.Dataset.Version || !before.Dataset.LastChangedAt.Equal(*after.Dataset.LastChangedAt) || !after.Dataset.LastCheckedAt.Equal(later) {
		t.Fatal("no-change timestamp semantics")
	}
	newSource := bytes.ReplaceAll(good, []byte("2026-10-24T18:28:52Z"), []byte("2026-10-24T19:28:52Z"))
	if err = s.sync(context.Background(), fixtureCameraFetcher{data: newSource}, later); err != nil {
		t.Fatal(err)
	}
	if !s.read().Dataset.SourceUpdatedAt.After(*after.Dataset.SourceUpdatedAt) || s.read().Dataset.Version != after.Dataset.Version {
		t.Fatal("source timestamp and record change must be independent")
	}
	after = s.read()
	reloaded, err := newCameraStore(dir)
	if err != nil || reloaded.read().Dataset.Version != after.Dataset.Version {
		t.Fatal("persistent reload", err)
	}
	missing := cameraElements()
	missing = append(missing[:1], missing[2:]...)
	var partial map[string]any
	_ = json.Unmarshal(good, &partial)
	all := partial["elements"].([]any)
	partial["elements"] = all[:len(all)-1]
	noCount, _ := json.Marshal(partial)
	regressed := bytes.ReplaceAll(good, []byte("2026-10-24T18:28:52Z"), []byte("2026-10-23T18:28:52Z"))
	for _, failed := range []fixtureCameraFetcher{{err: errors.New("offline")}, {data: cameraDocument(cameraElements(), "runtime error: timeout")}, {data: noCount}, {data: good[:len(good)/2]}, {data: cameraDocument(missing, "")}, {data: regressed}} {
		if err = s.sync(context.Background(), failed, later.Add(time.Hour)); err == nil {
			t.Fatal("accepted failed/partial import")
		}
		got := s.read()
		if !got.Dataset.LastCheckedAt.Equal(*after.Dataset.LastCheckedAt) || got.Dataset.Version != after.Dataset.Version {
			t.Fatal("failure modified snapshot")
		}
	}
	if err = os.Remove(filepath.Join(dir, "snapshot.json")); err != nil {
		t.Fatal(err)
	}
	if err = os.Mkdir(filepath.Join(dir, "snapshot.json"), 0750); err != nil {
		t.Fatal(err)
	}
	changed := cameraElements()
	changed[0].Tags["maxspeed"] = "90"
	changedData := bytes.ReplaceAll(cameraDocument(changed, ""), []byte("2026-10-24T18:28:52Z"), []byte("2026-10-24T19:28:52Z"))
	if err = s.sync(context.Background(), fixtureCameraFetcher{data: changedData}, later.Add(time.Hour)); err == nil {
		t.Fatal("expected rename failure")
	}
	if s.read().Dataset.Version != after.Dataset.Version {
		t.Fatal("write failure published")
	}
}
func TestCameraStoreChangedAndCorruptSnapshot(t *testing.T) {
	s, _ := newCameraStore(t.TempDir())
	now := time.Now()
	fetch := fixtureCameraFetcher{data: cameraDocument(cameraElements(), "")}
	if err := s.sync(context.Background(), fetch, now); err != nil {
		t.Fatal(err)
	}
	old := s.read()
	e := cameraElements()
	e[0].Tags["maxspeed"] = "90"
	later := now.Add(time.Hour)
	if err := s.sync(context.Background(), fixtureCameraFetcher{data: cameraDocument(e, "")}, later); err != nil {
		t.Fatal(err)
	}
	if s.read().Dataset.Version == old.Dataset.Version || !s.read().Dataset.LastChangedAt.Equal(later) {
		t.Fatal("changed dataset version/time")
	}
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "snapshot.json"), []byte("broken"), 0600); err != nil {
		t.Fatal(err)
	}
	bad, err := newCameraStore(dir)
	if err == nil || bad.read().Dataset.Version != "" {
		t.Fatal("corrupt snapshot not isolated")
	}
}

type cameraAttributes struct {
	attrs roadAttributes
	err   error
	calls int
}

func (p *cameraAttributes) attributesFor(context.Context, Route) (roadAttributes, error) {
	p.calls++
	return p.attrs, p.err
}
func cameraBBox(south, west, north, east float64) *CameraBBox {
	return &CameraBBox{&south, &west, &north, &east}
}
func TestCameraAPIBBoxRouteUnionAndRoadEvidence(t *testing.T) {
	s, _ := newCameraStore(t.TempDir())
	snapshot := emptyCameraSnapshot()
	snapshot.Cameras = []Camera{
		{ID: "viewport", Coordinate: Point{53, 6}, Kind: "fixed", Association: "unknown", SourceIDs: []string{"osm"}, Status: "mapped"},
		{ID: "route", Coordinate: Point{52.001, 5}, Kind: "fixed", Association: "on_way", RoadWayIDs: []int64{10}, RoadGeometry: []Point{{52, 5}, {52.002, 5}}, SourceIDs: []string{"osm"}, Status: "mapped"},
		{ID: "parallel", Coordinate: Point{52.001, 5.0001}, Kind: "fixed", Association: "on_way", RoadWayIDs: []int64{11}, SourceIDs: []string{"osm"}, Status: "mapped"},
	}
	snapshot.Zones = []AverageSpeedZone{{ID: "crossing", Start: &Point{52.999, 6}, End: &Point{53.001, 6}, Geometry: []Point{{52.999, 6}, {53.001, 6}}, GeometryVerified: true, Status: "mapped", SourceIDs: []string{"osm"}}}
	if err := s.publish(snapshot, time.Now()); err != nil {
		t.Fatal(err)
	}
	attrs := &cameraAttributes{attrs: roadAttributes{Edges: []roadEdge{{WayID: 10, Begin: 0, End: 1}}}}
	svc := newCameraService(s, attrs)
	q := CameraRequest{BBox: cameraBBox(52.9999, 5.9999, 53.0001, 6.0001)}
	got := svc.query(context.Background(), q, nil)
	if len(got.Cameras) != 1 || len(got.Zones) != 1 || attrs.calls != 0 {
		t.Fatal("bbox crossing/independence", got)
	}
	route := []Point{{52, 5}, {52.002, 5}}
	q.Route = &CameraRouteQuery{"polyline6", encodePolyline(route), 100}
	got = svc.query(context.Background(), q, route)
	if len(got.Cameras) != 3 || got.Cameras[1].RouteMatch != "confirmed" || got.Cameras[2].RouteMatch != "nearby" || got.Cameras[0].RouteMatch != "none" {
		t.Fatalf("union or identity evidence: %+v", got)
	}
	if math.Abs(*got.Cameras[1].RouteDistanceMeters-distance(route[0], route[1])/2) > 0.01 {
		t.Fatal("route distance must use geometric arclength")
	}
	if s.read().Cameras[1].RouteMatch != "" {
		t.Fatal("query mutated canonical snapshot")
	}
	wrongDirection := 180.0
	snapshot.Cameras[1].DirectionDegrees = &wrongDirection
	_ = s.publish(snapshot, time.Now())
	got = svc.query(context.Background(), q, route)
	if got.Cameras[1].RouteMatch != "nearby" {
		t.Fatal("opposite enforced direction must not confirm")
	}
	attrs.attrs.Edges = nil
	got = svc.query(context.Background(), q, route)
	if got.Cameras[1].RouteMatch != "nearby" || len(got.Warnings) == 0 {
		t.Fatal("missing identity must downgrade")
	}
	svc.limit = 1
	got = svc.query(context.Background(), q, route)
	if !got.Truncated || len(got.Cameras) != 1 {
		t.Fatal("truncation")
	}
}

func TestOverpassValidationAndSecondaryFallback(t *testing.T) {
	good := cameraDocument(cameraElements(), "")
	first := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" || !strings.Contains(r.Header.Get("User-Agent"), "RoadScout") {
			t.Error("missing polite import request")
		}
		_ = r.ParseForm()
		if r.Form.Get("data") != cameraQuery {
			t.Error("wrong query")
		}
		_, _ = w.Write(cameraDocument(cameraElements(), "runtime error: timeout"))
	}))
	defer first.Close()
	second := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write(good) }))
	defer second.Close()
	f := &overpassFetcher{client: first.Client(), endpoints: []string{first.URL, second.URL}}
	b, err := f.fetch(context.Background())
	if err != nil || !bytes.Equal(b, good) {
		t.Fatal("secondary fallback", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err = f.fetch(ctx); err == nil {
		t.Fatal("canceled fetch")
	}
}

type blockedCameraFetcher struct{ started chan struct{} }

func (f blockedCameraFetcher) fetch(ctx context.Context) ([]byte, error) {
	close(f.started)
	<-ctx.Done()
	return nil, ctx.Err()
}
func TestCameraBackgroundSyncDoesNotBlockReady(t *testing.T) {
	s, _ := newCameraStore(t.TempDir())
	f := blockedCameraFetcher{make(chan struct{})}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan struct{})
	go func() { s.runSync(ctx, f); close(done) }()
	<-f.started
	h := handler(&prototypeBase{}, newCameraService(s, nil))
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest("GET", "/readyz", nil))
	if w.Code != 200 {
		t.Fatal("sync blocked readiness")
	}
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("sync failed to stop")
	}
}
func TestCameraRouteZoneDirectionAndCrossing(t *testing.T) {
	s, _ := newCameraStore(t.TempDir())
	snapshot := emptyCameraSnapshot()
	snapshot.Zones = []AverageSpeedZone{{ID: "zone", Geometry: []Point{{52, 5}, {52.001, 5}, {52.002, 5}}, GeometryVerified: true, RoadWayIDs: []int64{10}}}
	_ = s.publish(snapshot, time.Now())
	attrs := &cameraAttributes{attrs: roadAttributes{Edges: []roadEdge{{WayID: 10, Begin: 0, End: 1}}}}
	svc := newCameraService(s, attrs)
	q := CameraRequest{BBox: cameraBBox(53, 6, 54, 7), Route: &CameraRouteQuery{CorridorMeters: 50}}
	for _, forward := range []bool{true, false} {
		route := []Point{{52, 5}, {52.002, 5}}
		if !forward {
			route[0], route[1] = route[1], route[0]
		}
		q.Route.Data = encodePolyline(route)
		got := svc.query(context.Background(), q, route)
		if len(got.Zones) != 1 {
			t.Fatal("zone route union")
		}
		want := "nearby"
		if forward {
			want = "confirmed"
		}
		if got.Zones[0].RouteMatch != want {
			t.Fatal("zone direction", got.Zones[0])
		}
	}
	if !geometryNearRoute(context.Background(), []Point{{52, 4.99}, {52, 5.01}}, []Point{{51.99, 5}, {52.01, 5}}, []float64{0, 2223}, 1) {
		t.Fatal("sparse crossing zone")
	}
}
func TestCameraHTTPValidationAndIndependentReadiness(t *testing.T) {
	s, _ := newCameraStore(t.TempDir())
	svc := newCameraService(s, nil)
	h := handler(&prototypeBase{ordinary: []Route{{ID: "ready-without-cameras"}}}, svc)
	for _, body := range []string{`{}`, `{"bbox":{"south":52,"north":53,"east":6}}`, `{"bbox":{"south":54,"west":5,"north":53,"east":6}}`, `{"bbox":{"south":52,"west":5,"north":53,"east":6},"extra":true}`, `{"bbox":{"south":52,"west":5,"north":53,"east":6},"route":{"encoding":"polyline6","data":"bad","corridorMeters":100}}`} {
		r := httptest.NewRequest("POST", "/v1/cameras", strings.NewReader(body))
		r.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != 400 {
			t.Fatalf("validation: %d %s", w.Code, w.Body.String())
		}
	}
	body := `{"bbox":{"south":52,"west":5,"north":53,"east":6}}`
	r := httptest.NewRequest("POST", "/v1/cameras", strings.NewReader(body))
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	var got CameraResponse
	if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &got) != nil || got.Warnings[0].Code != "camera_dataset_missing" || !got.Dataset.Stale || got.Cameras == nil || got.Zones == nil {
		t.Fatal("missing data response", w.Body.String())
	}
	w = httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest("GET", "/readyz", nil))
	if w.Code != 200 {
		t.Fatal("camera missing blocked readiness")
	}
	routeBody, _ := json.Marshal(request())
	r = httptest.NewRequest("POST", "/v1/routes", bytes.NewReader(routeBody))
	r.Header.Set("Content-Type", "application/json")
	w = httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 200 {
		t.Fatal("camera missing blocked routing", w.Body.String())
	}
}

func TestCameraConfirmationRequiresLocalEvidenceHTTP(t *testing.T) {
	route := []Point{{52, 5}, {52.002, 5}}
	north, south := 0.0, 180.0
	for _, tc := range []struct {
		name       string
		coordinate Point
		ways       []int64
		geometry   []Point
		direction  *float64
		edge       roadEdge
		want       string
	}{
		{"aligned_unknown_direction", Point{52.001, 5}, []int64{10}, route, nil, roadEdge{WayID: 10, Begin: 0, End: 1}, "confirmed"},
		{"identity_without_orientation", Point{52.001, 5}, []int64{10}, nil, nil, roadEdge{WayID: 10, Begin: 0, End: 1}, "nearby"},
		{"perpendicular_road", Point{52.001, 5}, []int64{10}, []Point{{52.001, 4.999}, {52.001, 5.001}}, nil, roadEdge{WayID: 10, Begin: 0, End: 1}, "nearby"},
		{"wrong_local_way", Point{52.001, 5}, []int64{11}, route, &north, roadEdge{WayID: 10, Begin: 0, End: 1}, "nearby"},
		{"wrong_edge_position", Point{52.001, 5}, []int64{10}, route, &north, roadEdge{WayID: 10, Begin: 1, End: 2}, "nearby"},
		{"opposite_enforced_travel", Point{52.001, 5}, []int64{10}, route, &south, roadEdge{WayID: 10, Begin: 0, End: 1}, "nearby"},
		{"beyond_route_endpoint", Point{52.0022, 5}, []int64{10}, route, &north, roadEdge{WayID: 10, Begin: 0, End: 1}, "nearby"},
		{"before_route_origin", Point{51.9998, 5}, []int64{10}, route, &north, roadEdge{WayID: 10, Begin: 0, End: 1}, "nearby"},
		{"bbox_without_corridor_match", Point{53, 6}, []int64{10}, route, &north, roadEdge{WayID: 10, Begin: 0, End: 1}, "none"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s, _ := newCameraStore(t.TempDir())
			snapshot := emptyCameraSnapshot()
			snapshot.Cameras = []Camera{{ID: "camera", Coordinate: tc.coordinate, Kind: "fixed", Association: "relation", RoadWayIDs: tc.ways, RoadGeometry: tc.geometry, DirectionDegrees: tc.direction, SourceIDs: []string{"osm:node:1"}, Status: "mapped"}}
			if err := s.publish(snapshot, time.Now()); err != nil {
				t.Fatal(err)
			}
			svc := newCameraService(s, &cameraAttributes{attrs: roadAttributes{Edges: []roadEdge{tc.edge}}})
			h := handler(&prototypeBase{}, svc)
			q := CameraRequest{BBox: cameraBBox(51, 4, 54, 7), Route: &CameraRouteQuery{"polyline6", encodePolyline(route), 100}}
			body, _ := json.Marshal(q)
			r := httptest.NewRequest("POST", "/v1/cameras", bytes.NewReader(body))
			r.Header.Set("Content-Type", "application/json")
			w := httptest.NewRecorder()
			h.ServeHTTP(w, r)
			var out CameraResponse
			if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &out) != nil || len(out.Cameras) != 1 || out.Cameras[0].RouteMatch != tc.want {
				t.Fatal(w.Code, w.Body.String())
			}
		})
	}
}

func TestCameraLifecycleFreshnessAndStartupDue(t *testing.T) {
	now := time.Now().UTC()
	recent := now.Add(-time.Hour)
	oldCheck := now.Add(-6 * time.Hour)
	oldSource := now.Add(-25 * time.Hour)
	future := now.Add(time.Hour)
	for _, tc := range []struct {
		name          string
		check, source *time.Time
		stale, due    bool
	}{
		{"missing", nil, nil, true, true},
		{"recent", &recent, &recent, false, false},
		{"due", &oldCheck, &recent, false, true},
		{"old_source_fresh_check", &recent, &oldSource, true, false},
		{"missing_source", &recent, nil, true, false},
		{"future_check", &future, &recent, true, true},
		{"future_source", &recent, &future, true, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			d := CameraDataset{LastCheckedAt: tc.check, SourceUpdatedAt: tc.source}
			if cameraDatasetStale(d, now) != tc.stale || cameraSyncDue(d, now) != tc.due {
				t.Fatal("freshness/due mismatch")
			}
		})
	}
	// A storage failure must retain the previous on-disk snapshot as well as memory.
	dir := t.TempDir()
	s, _ := newCameraStore(dir)
	fetch := fixtureCameraFetcher{data: cameraDocument(cameraElements(), "")}
	if err := s.sync(context.Background(), fetch, now); err != nil {
		t.Fatal(err)
	}
	old := s.read()
	s.dir = filepath.Join(dir, "snapshot.json")
	if err := s.sync(context.Background(), fetch, now.Add(time.Hour)); err == nil {
		t.Fatal("expected non-directory storage failure")
	}
	reloaded, err := newCameraStore(dir)
	if err != nil || reloaded.read().Dataset.Version != old.Dataset.Version || !reloaded.read().Dataset.LastCheckedAt.Equal(*old.Dataset.LastCheckedAt) || !s.read().Dataset.LastCheckedAt.Equal(*old.Dataset.LastCheckedAt) {
		t.Fatal("storage failure modified last good", err)
	}
}

func TestCameraIncompleteMembershipClearsTravelBearing(t *testing.T) {
	e := cameraElements()
	e = append(e, osmElement{Type: "relation", ID: 25, Tags: map[string]string{"type": "enforcement", "enforcement": "maxspeed"}, Members: []osmMember{{"node", 5, "device"}}})
	s, err := importCameras(cameraDocument(e, ""))
	if err != nil {
		t.Fatal(err)
	}
	if s.Cameras[1].DirectionDegrees != nil {
		t.Fatal("unresolved additional enforcement must not pick one known direction")
	}
}

// Opt-in check of a real import, without another source fetch, HTTP listener,
// Valhalla request or mutation of the imported snapshot.
func TestCameraImportedSnapshotContract(t *testing.T) {
	path := os.Getenv("CAMERA_SNAPSHOT_CHECK_PATH")
	if path == "" {
		t.Skip("set CAMERA_SNAPSHOT_CHECK_PATH to an imported snapshot.json")
	}
	s, err := newCameraStore(filepath.Dir(path))
	if err != nil {
		t.Fatal(err)
	}
	snapshot := s.read()
	if snapshot.Dataset.Version == "" || len(snapshot.Cameras) == 0 || snapshot.Dataset.LastChangedAt == nil {
		t.Fatal("missing imported data")
	}
	verified, incomplete := 0, 0
	for _, z := range snapshot.Zones {
		if !z.GeometryVerified {
			incomplete++
			if len(z.Geometry) != 0 {
				t.Fatal("unverified enforced path")
			}
			continue
		}
		verified++
		if len(z.Geometry) < 2 || z.Start == nil || z.End == nil || z.Geometry[0] != *z.Start || z.Geometry[len(z.Geometry)-1] != *z.End || len(z.RoadWayIDs) == 0 {
			t.Fatal("invalid verified zone", z.ID)
		}
	}
	if incomplete != snapshot.Dataset.IncompleteZoneCount {
		t.Fatal("incomplete statistics mismatch")
	}
	svc := newCameraService(s, nil)
	h := handler(&prototypeBase{}, svc)
	q := CameraRequest{BBox: cameraBBox(50, 3, 54, 8)}
	body, _ := json.Marshal(q)
	r := httptest.NewRequest("POST", "/v1/cameras", bytes.NewReader(body))
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	var out CameraResponse
	if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &out) != nil || out.Truncated || len(out.Cameras) != len(snapshot.Cameras) || len(out.Zones) != len(snapshot.Zones) {
		t.Fatal("NL viewport contract mismatch", w.Code)
	}
	for _, c := range out.Cameras {
		if c.RouteMatch != "" || c.RouteDistanceMeters != nil || c.RouteLateralMeters != nil {
			t.Fatal("bbox fabricated route evidence")
		}
	}
	copyStore, _ := newCameraStore(t.TempDir())
	if err = copyStore.publish(snapshot, time.Now()); err != nil {
		t.Fatal(err)
	}
	if copyStore.read().Dataset.Version != snapshot.Dataset.Version {
		t.Fatal("snapshot reload changed normalized version")
	}
	// The first publication into an empty test store is a change. A subsequent
	// identical publication must preserve that change timestamp and version.
	snapshot = copyStore.read()
	checked := snapshot.Dataset.LastCheckedAt.Add(time.Minute)
	if err = copyStore.publish(snapshot, checked); err != nil {
		t.Fatal(err)
	}
	after := copyStore.read()
	if after.Dataset.Version != snapshot.Dataset.Version || !after.Dataset.LastChangedAt.Equal(*snapshot.Dataset.LastChangedAt) || !after.Dataset.LastCheckedAt.Equal(checked) || cameraSyncDue(after.Dataset, checked) {
		t.Fatal("no-change/restart due semantics")
	}
	t.Logf("snapshot=%s cameras=%d verifiedZones=%d incompleteZones=%d source=%s version=%s", path, len(out.Cameras), verified, incomplete, out.Dataset.SourceUpdatedAt.Format(time.RFC3339), out.Dataset.Version)
}
