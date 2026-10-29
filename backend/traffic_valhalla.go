package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"sort"
	"strconv"
	"sync"
	"time"
)

type trafficEdge struct {
	ID     uint64   `json:"id"`
	Begin  int      `json:"begin_shape_index"`
	End    int      `json:"end_shape_index"`
	Length float64  `json:"length"`
	Speed  float64  `json:"speed"`
	Source *float64 `json:"source_percent_along"`
	Target *float64 `json:"target_percent_along"`
}
type trafficTrace struct {
	Shape     string            `json:"shape"`
	Edges     []trafficEdge     `json:"edges"`
	Alternate []json.RawMessage `json:"alternate_paths"`
}
type trafficMatch struct {
	Points []Point
	Edges  []trafficEdge
	At     time.Time
	Valid  bool
}

func (v *Valhalla) trafficStatus(ctx context.Context) (int64, error) {
	req, _ := http.NewRequestWithContext(ctx, "GET", v.BaseURL+"/status", nil)
	res, e := v.Client.Do(req)
	if e != nil {
		return 0, e
	}
	defer res.Body.Close()
	var body struct {
		Version string `json:"version"`
		Stamp   int64  `json:"tileset_last_modified"`
	}
	if res.StatusCode != 200 || json.NewDecoder(io.LimitReader(res.Body, 64000)).Decode(&body) != nil || body.Stamp == 0 {
		return 0, errors.New("graph identity unavailable")
	}
	return body.Stamp, nil
}
func (v *Valhalla) traceTraffic(ctx context.Context, points []Point, encoding, mode string) (trafficTrace, error) {
	payload := map[string]any{"costing": "auto", "shape_match": mode, "costing_options": map[string]any{"auto": map[string]any{"speed_types": []string{"freeflow", "constrained"}, "ignore_closures": true}}, "filters": map[string]any{"action": "include", "attributes": []string{"shape", "edge.id", "edge.begin_shape_index", "edge.end_shape_index", "edge.length", "edge.speed"}}}
	if encoding != "" {
		payload["encoded_polyline"] = encoding
	} else {
		shape := []map[string]float64{}
		for _, p := range points {
			shape = append(shape, map[string]float64{"lat": p.Latitude, "lon": p.Longitude})
		}
		payload["shape"] = shape
	}
	b, _ := json.Marshal(payload)
	req, _ := http.NewRequestWithContext(ctx, "POST", v.BaseURL+"/trace_attributes", bytes.NewReader(b))
	req.Header.Set("Content-Type", "application/json")
	res, e := v.Client.Do(req)
	if e != nil {
		return trafficTrace{}, e
	}
	defer res.Body.Close()
	var out trafficTrace
	if res.StatusCode != 200 || json.NewDecoder(io.LimitReader(res.Body, 8_000_000)).Decode(&out) != nil || len(out.Edges) == 0 {
		return out, errors.New("traffic matching unavailable")
	}
	return out, nil
}
func (s *trafficService) matchFlow(parent context.Context, snapshot *trafficProviderSnapshot) {
	if s.matcher == nil || (len(snapshot.Flow) == 0 && len(snapshot.Events) == 0) {
		return
	}
	ctx, cancel := context.WithTimeout(parent, 10*time.Second)
	defer cancel()
	stamp, e := s.matcher.trafficStatus(ctx)
	if e != nil {
		return
	}
	s.mu.Lock()
	if s.graphStamp != stamp {
		s.matches = map[string]trafficMatch{}
		s.graphStamp = stamp
	}
	s.mu.Unlock()
	s.mu.Lock()
	wanted := map[string]time.Time{}
	for key, at := range s.wanted {
		if s.now().Sub(at) > 5*time.Minute {
			delete(s.wanted, key)
		} else {
			wanted[key] = at
		}
	}
	s.mu.Unlock()
	sort.SliceStable(snapshot.Flow, func(i, j int) bool {
		a, okA := wanted[snapshot.Flow[i].ID]
		b, okB := wanted[snapshot.Flow[j].ID]
		if okA != okB {
			return okA
		}
		if okA && !a.Equal(b) {
			return a.After(b)
		}
		return snapshot.Flow[i].Congestion == "heavy" && snapshot.Flow[j].Congestion != "heavy"
	})
	matching := []TrafficFeature{}
	eventIndices := map[string]int{}
	for i, f := range snapshot.Events {
		if f.Closed && eventActive(f, s.now()) {
			eventIndices[f.ID] = i
			matching = append(matching, f)
		}
	}
	eventCount := len(matching)
	matching = append(matching, snapshot.Flow...)
	attempts := 0
	for i := range matching {
		f := &matching[i]
		key := fmt.Sprintf("%s:%s:%d", f.ID, f.Version, stamp)
		s.mu.RLock()
		m, exists := s.matches[key]
		s.mu.RUnlock()
		if exists && !m.Valid && s.now().Sub(m.At) > 15*time.Minute {
			exists = false
		}
		if !exists && attempts < s.config.MaxMatchesPerSync && ctx.Err() == nil {
			attempts++
			m.At = s.now()
			points := f.Points
			if len(points) == 2 {
				a, b := points[0], points[1]
				points = []Point{a, {Latitude: (a.Latitude + b.Latitude) / 2, Longitude: (a.Longitude + b.Longitude) / 2}, b}
			}
			if len(points) > 500 {
				continue
			}
			trace, err := s.matcher.traceTraffic(ctx, points, "", "map_snap")
			if err == nil && len(trace.Alternate) == 0 {
				matched, err := decodePolyline(trace.Shape)
				if err == nil && len(matched) >= 2 {
					mc, sc := cameraCumulative(matched), cameraCumulative(f.Points)
					ratio := mc[len(mc)-1] / math.Max(1, sc[len(sc)-1])
					valid := ratio >= 0.6 && ratio <= 1.6
					for _, p := range f.Points {
						if projectOnRoute(p, matched, mc).lateral > 25 {
							valid = false
						}
					}
					for _, p := range matched {
						if projectOnRoute(p, f.Points, sc).lateral > 25 {
							valid = false
						}
					}
					if valid {
						m.Valid = true
						m.Points = matched
						m.Edges = trace.Edges
						if f.Closed {
							reverse := append([]Point(nil), points...)
							for a, b := 0, len(reverse)-1; a < b; a, b = a+1, b-1 {
								reverse[a], reverse[b] = reverse[b], reverse[a]
							}
							if opposite, err := s.matcher.traceTraffic(ctx, reverse, "", "map_snap"); err == nil && len(opposite.Alternate) == 0 {
								if rp, err := decodePolyline(opposite.Shape); err == nil && len(rp) > 1 && distance(rp[0], points[len(points)-1]) < 25 && distance(rp[len(rp)-1], points[0]) < 25 {
									rc := cameraCumulative(rp)
									ok := rc[len(rc)-1]/math.Max(1, sc[len(sc)-1]) <= 1.6
									for _, p := range rp {
										if projectOnRoute(p, f.Points, sc).lateral > 25 {
											ok = false
										}
									}
									if ok {
										m.Edges = append(m.Edges, opposite.Edges...)
									}
								}
							}
						}
					}
				}
			}
			s.mu.Lock()
			if len(s.matches) > 100_000 {
				s.matches = map[string]trafficMatch{}
			}
			s.matches[key] = m
			s.mu.Unlock()
		}
		if m.Valid {
			f.Matched = true
			f.GraphStamp = stamp
			f.Points = m.Points
			f.Edges = m.Edges
			setTrafficGeometry(f)
			if f.TravelSeconds != nil && *f.TravelSeconds > 0 {
				c := cameraCumulative(f.Points)
				speed := c[len(c)-1] / *f.TravelSeconds * 3.6
				if speed >= 0 && speed <= 252 {
					f.SpeedKph = &speed
				}
			}
		}
	}
	snapshot.Flow = matching[eventCount:]
	for i := 0; i < eventCount; i++ {
		snapshot.Events[eventIndices[matching[i].ID]] = matching[i]
	}
}

type trafficBridgeStatus struct {
	EngineVersion string    `json:"engineVersion"`
	GraphVersion  string    `json:"graphVersion"`
	Stamp         int64     `json:"tilesetLastModified"`
	Ready         bool      `json:"liveTrafficReady"`
	SnapshotID    string    `json:"snapshotId"`
	ExpiresAt     time.Time `json:"expiresAt"`
}
type trafficBridge struct {
	base      string
	client    *http.Client
	now       func() time.Time
	mu        sync.RWMutex
	status    trafficBridgeStatus
	checked   time.Time
	publishMu sync.Mutex
}

func (b *trafficBridge) ready(stamp int64) bool {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return b.status.Ready && b.status.EngineVersion == "3.5.1" && b.status.GraphVersion != "" && b.status.SnapshotID != "" && b.status.Stamp == stamp && b.status.ExpiresAt.After(b.now().Add(20*time.Second)) && b.now().Sub(b.checked) < 90*time.Second
}
func (s *trafficService) liveReady() bool {
	s.mu.RLock()
	stamp := s.graphStamp
	s.mu.RUnlock()
	return s.config.Enabled && s.bridge != nil && s.bridge.ready(stamp)
}
func (s *trafficService) nativeReady(ctx context.Context) bool {
	if !s.liveReady() || s.matcher == nil {
		return false
	}
	stamp, e := s.matcher.trafficStatus(ctx)
	if e != nil {
		return false
	}
	return s.bridge.ready(stamp)
}
func (s *trafficService) publishBridge(parent context.Context) {
	b := s.bridge
	b.publishMu.Lock()
	defer b.publishMu.Unlock()
	ctx, cancel := context.WithTimeout(parent, 8*time.Second)
	defer cancel()
	b.mu.Lock()
	b.status.Ready = false
	b.mu.Unlock()
	req, _ := http.NewRequestWithContext(ctx, "GET", b.base+"/healthz", nil)
	res, e := b.client.Do(req)
	if e != nil {
		return
	}
	var health trafficBridgeStatus
	e = json.NewDecoder(io.LimitReader(res.Body, 64000)).Decode(&health)
	res.Body.Close()
	if e != nil || health.EngineVersion != "3.5.1" || health.GraphVersion == "" {
		return
	}
	s.mu.RLock()
	stamp := s.graphStamp
	s.mu.RUnlock()
	if stamp == 0 || health.Stamp != stamp {
		return
	}
	type update struct {
		ID     string   `json:"graphId"`
		Speed  *float64 `json:"speedKph"`
		Closed bool     `json:"closed"`
	}
	features, _ := s.features()
	byID := map[uint64]struct {
		update update
		at     time.Time
		priority int
	}{}
	priorities:=map[string]int{};for _,p:=range s.config.Providers{priorities[p.ID]=p.Priority}
	expiry := s.now().Add(180 * time.Second)
	for _, f := range features {
		if !f.Matched || !f.DirectionKnown || (f.SpeedKph == nil && !f.Closed) {
			continue
		}
		until := f.ObservedAt.Add(180 * time.Second)
		if f.ValidUntil != nil && f.ValidUntil.Before(until) {
			until = *f.ValidUntil
		}
		if !until.After(s.now().Add(30 * time.Second)) {
			continue
		}
		if until.Before(expiry) {
			expiry = until
		}
		for _, edge := range f.Edges {
			if edge.ID == 0 || (!f.Closed && ((edge.Source != nil && *edge.Source > 0.2) || (edge.Target != nil && *edge.Target < 0.8))) {
				continue
			}
			prior, exists := byID[edge.ID]
			if exists && ((prior.update.Closed && !f.Closed) || (!f.Closed && (f.ObservedAt.Before(prior.at)||(f.ObservedAt.Equal(prior.at)&&priorities[f.SourceID]<=prior.priority)))) {
				continue
			}
			var speed *float64
			if !f.Closed {
				value := math.Max(2, *f.SpeedKph)
				speed = &value
			}
			byID[edge.ID] = struct {
				update update
				at     time.Time
				priority int
			}{update{strconv.FormatUint(edge.ID, 10), speed, f.Closed}, f.ObservedAt, priorities[f.SourceID]}
		}
	}
	edges := []update{}
	for _, entry := range byID {
		edges = append(edges, entry.update)
	}
	id := identifier()
	payload := map[string]any{"graphVersion": health.GraphVersion, "snapshotId": id, "expiresAt": expiry.UTC(), "edges": edges}
	data, _ := json.Marshal(payload)
	req, _ = http.NewRequestWithContext(ctx, "PUT", b.base+"/v1/traffic/snapshot", bytes.NewReader(data))
	req.Header.Set("Content-Type", "application/json")
	res, e = b.client.Do(req)
	if e != nil {
		return
	}
	defer res.Body.Close()
	var applied trafficBridgeStatus
	if res.StatusCode != 200 || json.NewDecoder(io.LimitReader(res.Body, 64000)).Decode(&applied) != nil {
		return
	}
	if applied.GraphVersion != health.GraphVersion || applied.Stamp != stamp || applied.SnapshotID != id || applied.ExpiresAt.After(expiry.Add(time.Second)) || len(edges) == 0 {
		return
	}
	b.mu.Lock()
	b.status = applied
	b.checked = s.now()
	b.mu.Unlock()
}

type RouteTraffic struct {
	Mode            string     `json:"mode"`
	SnapshotID      string     `json:"snapshotId,omitempty"`
	ExpiresAt       *time.Time `json:"expiresAt,omitempty"`
	CoveragePercent float64    `json:"coveragePercent"`
	Token           string     `json:"token,omitempty"`
	CorridorKey     string     `json:"corridorKey,omitempty"`
	LeadMeters      float64    `json:"leadMeters,omitempty"`
}
type trafficRouteContext struct {
	Route   Route
	Request RouteRequest
	Expires time.Time
	Edges   []trafficEdge
	Stamp   int64
}

func(s *trafficService)routeAttributions(routes []Route)[]string{
	out:=[]string{"© OpenStreetMap contributors — ODbL"};live:=false;for _,r:=range routes{if r.Traffic!=nil&&r.Traffic.Mode=="live_partial"{live=true}}
	if live{seen:=map[string]bool{};for _,p:=range s.config.Providers{if p.Enabled&&p.Attribution!=""&&!seen[p.Attribution]{out=append(out,p.Attribution);seen[p.Attribution]=true}}};return out
}

func (s *trafficService) decorate(ctx context.Context, routes []Route, request RouteRequest) {
	if s.matcher != nil && s.config.Enabled {
		s.mu.RLock()
		missing := s.graphStamp == 0
		s.mu.RUnlock()
		if missing {
			if stamp, e := s.matcher.trafficStatus(ctx); e == nil {
				s.mu.Lock()
				if s.graphStamp == 0 {
					s.graphStamp = stamp
				}
				s.mu.Unlock()
			}
		}
	}
	available := s.nativeReady(ctx)
	currentSnapshot:="";if available{s.bridge.mu.RLock();currentSnapshot=s.bridge.status.SnapshotID;s.bridge.mu.RUnlock()}
	features, _ := s.features()
	ids := map[uint64]bool{}
	for _, f := range features {
		if f.Matched && f.Kind == "flow" && f.SpeedKph != nil {
			for _, e := range f.Edges {
				ids[e.ID] = true
			}
		}
	}
	for i := range routes {
		r := &routes[i]
		live:=available&&r.Traffic!=nil&&r.Traffic.Mode=="live_partial"&&r.Traffic.SnapshotID==currentSnapshot
		mode:="unavailable";if live{mode="live_partial"}
		info := &RouteTraffic{Mode: mode}
		if live {r.Timing.Traffic="live_partial"}
		var routeEdges []trafficEdge
		if s.matcher != nil && s.config.Enabled {
			trace, e := s.matcher.traceTraffic(ctx, nil, r.Geometry.Data, "edge_walk")
			if e == nil {
				routeEdges = trace.Edges
				total, covered := 0.0, 0.0
				for _, edge := range trace.Edges {
					total += edge.Length
					if ids[edge.ID] {
						covered += edge.Length
					}
				}
				if total > 0 {
					info.CoveragePercent = covered / total * 100
				}
			}
		}
		if live {
			s.bridge.mu.RLock()
			status := s.bridge.status
			s.bridge.mu.RUnlock()
			info.SnapshotID = status.SnapshotID
			until := status.ExpiresAt
			info.ExpiresAt = &until
		}
		info.Token = identifier()
		r.Traffic = info
		s.mu.Lock()
		if s.routes == nil {
			s.routes = map[string]trafficRouteContext{}
		}
		for key, c := range s.routes {
			if !c.Expires.After(s.now()) {
				delete(s.routes, key)
			}
		}
		if len(s.routes) >= 512 {
			for key := range s.routes {
				delete(s.routes, key)
				break
			}
		}
		s.routes[info.Token] = trafficRouteContext{Route: *r, Request: request, Expires: s.now().Add(30 * time.Minute), Edges: routeEdges, Stamp: s.graphStamp}
		s.mu.Unlock()
	}
}

// Preserve the selected geometry for ETA refresh; this is not a new route search.
func (s *trafficService) remainingETA(ctx context.Context, r Route, meters float64) (float64, trafficTrace, error) {
	p, e := decodePolyline(r.Geometry.Data)
	if e != nil {
		return 0, trafficTrace{}, e
	}
	c := cameraCumulative(p)
	if !finite(meters) || meters < 0 || meters >= c[len(c)-1] {
		return 0, trafficTrace{}, errors.New("invalid progress")
	}
	p = sliceGeometry(p, c, meters, c[len(c)-1])
	encoded := encodePolyline(p)
	payload := map[string]any{"encoded_polyline": encoded, "shape_match": "edge_walk", "costing": "auto", "date_time": map[string]any{"type": 0}, "costing_options": map[string]any{"auto": map[string]any{"speed_types": []string{"freeflow", "constrained", "predicted", "current"}}}, "units": "kilometers", "language": r.Language}
	data, _ := json.Marshal(payload)
	req, _ := http.NewRequestWithContext(ctx, "POST", s.matcher.BaseURL+"/trace_route", bytes.NewReader(data))
	req.Header.Set("Content-Type", "application/json")
	res, e := s.matcher.Client.Do(req)
	if e != nil {
		return 0, trafficTrace{}, e
	}
	defer res.Body.Close()
	var response vhResponse
	if res.StatusCode != 200 || json.NewDecoder(io.LimitReader(res.Body, 8_000_000)).Decode(&response) != nil || !finite(response.Trip.Summary.Time) || response.Trip.Summary.Time < 0 {
		return 0, trafficTrace{}, errors.New("traffic ETA unavailable")
	}
	trace, e := s.matcher.traceTraffic(ctx, nil, encoded, "edge_walk")
	return response.Trip.Summary.Time, trace, e
}
func trafficCorridor(a, b []trafficEdge) (string, float64) {
	i := 0
	meters := 0.0
	for i < len(a) && i < len(b) && a[i].ID == b[i].ID {
		meters += a[i].Length * 1000
		i++
	}
	if i == len(b) || i == len(a) {
		return "", 0
	}
	end := i + 4
	if end > len(b) {
		end = len(b)
	}
	h := sha256.New()
	for _, edge := range b[i:end] {
		fmt.Fprintf(h, "%d,", edge.ID)
	}
	return hex.EncodeToString(h.Sum(nil)), meters
}

func (s *trafficService) serveRouteHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	if r.Header.Get("Content-Type") != "application/json" {
		w.WriteHeader(415)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	defer r.Body.Close()
	d := json.NewDecoder(r.Body)
	d.DisallowUnknownFields()
	var q struct {
		Token    string    `json:"token"`
		Position Point     `json:"position"`
		Heading  *float64  `json:"heading"`
		Speed    float64   `json:"speedMps"`
		At       time.Time `json:"at"`
		Traveled float64   `json:"traveledMeters"`
		Check    bool      `json:"checkAlternatives"`
	}
	if d.Decode(&q) != nil || d.Decode(new(any)) != io.EOF || !q.Position.valid() || !finite(q.Traveled) || q.Traveled < 0 || !finite(q.Speed) || q.Speed < 0 || q.Speed > 100 || q.At.IsZero() || math.Abs(s.now().Sub(q.At).Seconds()) > 10 || (q.Heading != nil && (!finite(*q.Heading) || *q.Heading < 0 || *q.Heading >= 360)) {
		w.WriteHeader(400)
		return
	}
	s.mu.Lock()
	entry, exists := s.routes[q.Token]
	if exists && entry.Expires.After(s.now()) {
		entry.Expires = s.now().Add(30 * time.Minute)
		s.routes[q.Token] = entry
	} else {
		exists = false
	}
	s.mu.Unlock()
	if !exists {
		w.WriteHeader(410)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()
	reply := map[string]any{"generatedAt": s.now().UTC(), "routingEnabled": false}
	if !s.nativeReady(ctx) {
		_ = json.NewEncoder(w).Encode(reply)
		return
	}
	select {
	case s.slots <- struct{}{}:
		defer func() { <-s.slots }()
	default:
		w.WriteHeader(429)
		return
	}
	points, e := decodePolyline(entry.Route.Geometry.Data)
	if e != nil {
		w.WriteHeader(410)
		return
	}
	c := cameraCumulative(points)
	projection := projectOnRoute(q.Position, points, c)
	if projection.lateral > 75 || math.Abs(projection.along-q.Traveled) > 100 {
		w.WriteHeader(409)
		return
	}
	seconds, trace, e := s.remainingETA(ctx, entry.Route, q.Traveled)
	if e != nil {
		_ = json.NewEncoder(w).Encode(reply)
		return
	}
	reply["routingEnabled"] = true
	reply["remainingSeconds"] = seconds
	s.bridge.mu.RLock()
	reply["expiresAt"] = s.bridge.status.ExpiresAt
	etaSnapshot:=s.bridge.status.SnapshotID
	s.bridge.mu.RUnlock()
	if q.Check && s.routing != nil {
		request := entry.Request
		request.Waypoints = append([]WaypointRequest(nil), request.Waypoints...)
		request.Waypoints[0].Coordinate = q.Position
		request.Waypoints[0].Heading = q.Heading
		routes, warnings, err := s.routing.Routes(ctx, request)
		if err == nil {
			eligible := []Route{}
			for _, route := range routes {
				if route.Traffic==nil||route.Traffic.Mode!="live_partial"||route.Traffic.SnapshotID!=etaSnapshot{continue}
				saving := seconds - route.Summary.Duration
				if saving < 120 || saving < seconds*0.05 {
					continue
				}
				alternative, e := s.matcher.traceTraffic(ctx, nil, route.Geometry.Data, "edge_walk")
				if e != nil {
					continue
				}
				key, lead := trafficCorridor(trace.Edges, alternative.Edges)
				if key == "" || lead/math.Max(5, q.Speed) < 60 {
					continue
				}
				route.Traffic.CorridorKey=key;route.Traffic.LeadMeters=lead
				eligible = append(eligible, route)
			}
			if len(eligible) > 0 {
				s.decorate(ctx, eligible, request)
				for i := range eligible {
					alternative, e := s.matcher.traceTraffic(ctx, nil, eligible[i].Geometry.Data, "edge_walk")
					if e == nil {
						eligible[i].Traffic.CorridorKey, eligible[i].Traffic.LeadMeters = trafficCorridor(trace.Edges, alternative.Edges)
					}
				}
				reply["alternatives"] = RouteResponse{identifier(), s.now().UTC(), eligible, warnings, s.routeAttributions(eligible), Provenance{"valhalla", "1", ""}}
			}
		}
	}
	if !s.nativeReady(ctx) {
		reply = map[string]any{"generatedAt": s.now().UTC(), "routingEnabled": false}
	}
	_ = json.NewEncoder(w).Encode(reply)
}
