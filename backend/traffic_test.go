package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func trafficXMLFixture(at time.Time, body string) string {
	return `<messageContainer xmlns="http://datex2.eu/schema/3/messageContainer" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><publicationTime>` + at.Format(time.RFC3339) + `</publicationTime>` + body + `</messageContainer>`
}

func TestTrafficDefaultConfigWorksWithoutMountedFile(t *testing.T) {
	config, err := loadTrafficConfig("")
	if err != nil {
		t.Fatal(err)
	}
	if !config.Enabled || config.EnableRouting || config.BridgeURL != "" || len(config.Providers) != 1 {
		t.Fatalf("unexpected built-in traffic defaults: %+v", config)
	}
	provider := config.Providers[0]
	if !provider.Enabled || provider.ID != "ndw-nl" || provider.Adapter != "ndw-datex3" || provider.EventsURL == "" || provider.SitesURL == "" || provider.MeasurementsURL == "" {
		t.Fatalf("NDW defaults are incomplete: %+v", provider)
	}
}
func TestTrafficDATEX3JoinsVersionsAndKeepsObservationTime(t *testing.T) {
	now := time.Date(2026, 10, 28, 12, 0, 0, 0, time.UTC)
	sites := trafficXMLFixture(now, `<measurementSite id="site" version="2"><measurementSpecificCharacteristics index="1"><specificMeasurementValueType>travelTimeInformation</specificMeasurementValueType></measurementSpecificCharacteristics><gmlLineString><posList>52 5 52.001 5</posList></gmlLineString></measurementSite>`)
	configuration, e := parseNDWTraffic(strings.NewReader(sites), "sites", "nl", nil)
	if e != nil || len(configuration.Sites) != 1 {
		t.Fatal(configuration, e)
	}
	body := `<siteMeasurements><measurementSiteReference id="site" version="2"/><physicalQuantity index="1"><basicData xsi:type="roa:TravelTimeData"><travelTime><duration>120.5</duration></travelTime><normallyExpectedTravelTime><duration>60</duration></normallyExpectedTravelTime></basicData></physicalQuantity><measurementTimeDefault><timeValue>2026-10-28T13:00:00+01:00</timeValue></measurementTimeDefault></siteMeasurements>`
	flow, e := parseNDWTraffic(strings.NewReader(trafficXMLFixture(now, body)), "flow", "nl", configuration.Sites)
	if e != nil || len(flow.Features) != 1 {
		t.Fatal(flow, e)
	}
	f := flow.Features[0]
	if f.ObservedAt != now || *f.TravelSeconds != 120.5 || f.Congestion != "heavy" || f.Matched {
		t.Fatal(f)
	}
	wrong := strings.Replace(body, `version="2"`, `version="3"`, 1)
	flow, e = parseNDWTraffic(strings.NewReader(trafficXMLFixture(now, wrong)), "flow", "nl", configuration.Sites)
	if e != nil || len(flow.Features) != 0 {
		t.Fatal("wrong site version accepted", e)
	}
}
func TestTrafficCompleteEmptyPublicationAndMalformedFeed(t *testing.T) {
	now := time.Now().UTC()
	valid := trafficXMLFixture(now, "")
	d, e := parseNDWTraffic(strings.NewReader(valid), "events", "nl", nil)
	if e != nil || len(d.Features) != 0 {
		t.Fatal(d, e)
	}
	for _, body := range []string{strings.TrimSuffix(valid, "</messageContainer>"), valid + valid, strings.Replace(valid, "schema/3/", "schema/2/", 1)} {
		if _, e := parseNDWTraffic(strings.NewReader(body), "events", "nl", nil); e == nil {
			t.Fatal("malformed/unsupported document accepted")
		}
	}
}
func TestTrafficLongLivedEventUsesPublicationHeartbeatAndValidity(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	body := `<situationRecord id="closure" version="1" xsi:type="sit:RoadOrCarriagewayOrLaneManagement"><probabilityOfOccurrence>certain</probabilityOfOccurrence><operatorActionStatus>approved</operatorActionStatus><roadOrCarriagewayOrLaneManagementType>roadClosed</roadOrCarriagewayOrLaneManagementType><overallStartTime>` + now.Add(-30*24*time.Hour).Format(time.RFC3339) + `</overallStartTime><overallEndTime>` + now.Add(time.Hour).Format(time.RFC3339) + `</overallEndTime><gmlLineString srsName="WGS 84"><posList>52 5 52.001 5</posList></gmlLineString></situationRecord>`
	d, e := parseNDWTraffic(strings.NewReader(trafficXMLFixture(now, body)), "events", "nl", nil)
	if e != nil || len(d.Features) != 1 {
		t.Fatal(d, e)
	}
	f := d.Features[0]
	if !eventActive(f, now) || !f.Closed || f.Matched {
		t.Fatal(f)
	}
	c := defaultTrafficConfig()
	s := newTrafficService(c, nil)
	s.now = func() time.Time { return now }
	s.snapshots[c.Providers[0].ID] = trafficProviderSnapshot{Events: d.Features, EventsAt: now}
	features, _ := s.features()
	if len(features) != 1 {
		t.Fatal("fresh long-lived event lost")
	}
	s.now = func() time.Time { return now.Add(4 * time.Minute) }
	features, _ = s.features()
	if len(features) != 0 {
		t.Fatal("stale publication used")
	}
}
func TestTrafficBBoxIncludesCrossingGeometryAndDoesNotConfirmByProximity(t *testing.T) {
	now := time.Now().UTC()
	c := defaultTrafficConfig()
	s := newTrafficService(c, nil)
	s.now = func() time.Time { return now }
	f := TrafficFeature{ID: "event", SourceID: "ndw-nl", Kind: "incident", Points: []Point{{52, 4}, {52, 6}}, ObservedAt: now}
	setTrafficGeometry(&f)
	s.snapshots["ndw-nl"] = trafficProviderSnapshot{Events: []TrafficFeature{f}, EventsAt: now}
	q := `{"bbox":{"south":51.99,"north":52.01,"west":4.99,"east":5.01}}`
	r := httptest.NewRequest("POST", "/v1/traffic", strings.NewReader(q))
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	s.serveHTTP(w, r)
	var response TrafficResponse
	if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &response) != nil || len(response.Features) != 1 || response.Features[0].Matched || response.RoutingEnabled {
		t.Fatal(w.Body.String())
	}
}
func TestTrafficBridgeRequiresGraphIdentityFreshnessAndAcknowledgedSnapshot(t *testing.T) {
	now := time.Now().UTC()
	stamp := int64(42)
	native := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{"version": "3.5.1", "tileset_last_modified": stamp})
	}))
	defer native.Close()
	v, _ := newValhalla(native.URL)
	s := newTrafficService(TrafficConfig{Enabled: true, EnableRouting: true, BridgeURL: "http://bridge.invalid"}, v)
	s.now = func() time.Time { return now }
	s.bridge.now = s.now
	s.graphStamp = 42
	s.bridge.status = trafficBridgeStatus{EngineVersion: "3.5.1", GraphVersion: "hash", Stamp: 42, Ready: true, SnapshotID: "snapshot", ExpiresAt: now.Add(time.Minute)}
	s.bridge.checked = now
	if !s.nativeReady(context.Background()) {
		t.Fatal("valid native bridge rejected")
	}
	stamp = 43
	if s.nativeReady(context.Background()) {
		t.Fatal("graph change accepted")
	}
	stamp = 42
	s.bridge.status.ExpiresAt = now.Add(10 * time.Second)
	if s.nativeReady(context.Background()) {
		t.Fatal("near-expired snapshot accepted")
	}
}
func TestTrafficNativePublisherDistinguishesStoppedTrafficAndClosure(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	var received map[string]any
	bridge := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		health := trafficBridgeStatus{EngineVersion: "3.5.1", GraphVersion: "hash", Stamp: 42}
		if r.Method == "PUT" {
			if json.NewDecoder(r.Body).Decode(&received) != nil {
				t.Error("invalid update")
			}
			health.Ready = true
			health.SnapshotID = received["snapshotId"].(string)
			health.ExpiresAt = *parseTrafficTime(received["expiresAt"].(string))
		}
		_ = json.NewEncoder(w).Encode(health)
	}))
	defer bridge.Close()
	c := defaultTrafficConfig()
	c.EnableRouting = true
	c.BridgeURL = bridge.URL
	s := newTrafficService(c, nil)
	s.now = func() time.Time { return now }
	s.bridge.now = s.now
	s.graphStamp = 42
	zero := 0.0
	flow := TrafficFeature{ID: "flow", SourceID: "ndw-nl", Kind: "flow", ObservedAt: now, Matched: true, DirectionKnown: true, SpeedKph: &zero, GraphStamp: 42, Edges: []trafficEdge{{ID: 10, Length: 1}}}
	closure := TrafficFeature{ID: "closed", SourceID: "ndw-nl", Kind: "closure", ObservedAt: now, Matched: true, DirectionKnown: true, Closed: true, GraphStamp: 42, Edges: []trafficEdge{{ID: 11, Length: 1}}}
	s.snapshots["ndw-nl"] = trafficProviderSnapshot{Flow: []TrafficFeature{flow}, FlowAt: now, Events: []TrafficFeature{closure}, EventsAt: now}
	s.publishBridge(context.Background())
	if !s.liveReady() {
		t.Fatal("acknowledged snapshot not ready")
	}
	edges := received["edges"].([]any)
	if len(edges) != 2 {
		t.Fatal(received)
	}
	for _, raw := range edges {
		e := raw.(map[string]any)
		if e["graphId"] == "10" && (e["closed"] != false || e["speedKph"] != float64(2)) {
			t.Fatal(e)
		}
		if e["graphId"] == "11" && (e["closed"] != true || e["speedKph"] != nil) {
			t.Fatal(e)
		}
	}
}
func TestTrafficUnavailableNeverRequestsCurrentSpeedsOrClosures(t *testing.T) {
	var options map[string]any
	response := fixture(t)
	native := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		options = body["costing_options"].(map[string]any)["auto"].(map[string]any)
		_ = json.NewEncoder(w).Encode(response)
	}))
	defer native.Close()
	v, _ := newValhalla(native.URL)
	v.traffic = newTrafficService(defaultTrafficConfig(), v)
	if _, _, e := v.Routes(context.Background(), request()); e != nil {
		t.Fatal(e)
	}
	if options["ignore_closures"] != true {
		t.Fatal(options)
	}
	for _, speed := range options["speed_types"].([]any) {
		if speed == "current" {
			t.Fatal("stale live speed enabled")
		}
	}
}
func TestTrafficContextExpiresAndReadinessIsIndependent(t *testing.T) {
	now := time.Now().UTC()
	s := newTrafficService(defaultTrafficConfig(), nil)
	s.now = func() time.Time { return now }
	route, e := normalize(fixture(t).Trip, request())
	if e != nil {
		t.Fatal(e)
	}
	routes := []Route{route}
	s.decorate(context.Background(), routes, request())
	token := routes[0].Traffic.Token
	q := fmt.Sprintf(`{"token":%q,"position":{"latitude":52.09,"longitude":5.12},"speedMps":10,"at":%q,"traveledMeters":0,"checkAlternatives":true}`, token, now.Format(time.RFC3339Nano))
	r := httptest.NewRequest("POST", "/v1/traffic/route", bytes.NewBufferString(q))
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	s.serveRouteHTTP(w, r)
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"routingEnabled":false`) {
		t.Fatal(w.Code, w.Body.String())
	}
	s.routes[token] = trafficRouteContext{Route: route, Expires: now.Add(-time.Second)}
	r = httptest.NewRequest("POST", "/v1/traffic/route", strings.NewReader(q))
	r.Header.Set("Content-Type", "application/json")
	w = httptest.NewRecorder()
	s.serveRouteHTTP(w, r)
	if w.Code != 410 {
		t.Fatal(w.Code)
	}
}
