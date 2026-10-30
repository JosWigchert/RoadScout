package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
)

type TrafficProviderConfig struct {
	ID              string   `json:"id"`
	Adapter         string   `json:"adapter"`
	Countries       []string `json:"countries"`
	Enabled         bool     `json:"enabled"`
	EventsURL       string   `json:"eventsURL"`
	SitesURL        string   `json:"sitesURL"`
	MeasurementsURL string   `json:"measurementsURL"`
	CredentialEnv   string   `json:"credentialEnv,omitempty"`
	Attribution     string   `json:"attribution"`
	PollSeconds     int      `json:"pollSeconds"`
	MaxAgeSeconds   int      `json:"maxAgeSeconds"`
	Priority        int      `json:"priority"`
}
type TrafficConfig struct {
	Enabled           bool                    `json:"enabled"`
	Providers         []TrafficProviderConfig `json:"providers"`
	BridgeURL         string                  `json:"bridgeURL,omitempty"`
	EnableRouting     bool                    `json:"enableRouting"`
	MaxMatchesPerSync int                     `json:"maxMatchesPerSync"`
}

func defaultTrafficConfig() TrafficConfig {
	return TrafficConfig{Enabled: true, MaxMatchesPerSync: 50, Providers: []TrafficProviderConfig{{
		ID: "ndw-nl", Adapter: "ndw-datex3", Countries: []string{"NL"}, Enabled: true,
		EventsURL:       "https://opendata.ndw.nu/actueel_beeld.xml.gz",
		SitesURL:        "https://opendata.ndw.nu/reistijden_configuratie_meetlocaties.xml.gz",
		MeasurementsURL: "https://opendata.ndw.nu/reistijden_meetgegevens.xml.gz",
		Attribution:     "Traffic data: NDW · CC0 unless stated otherwise", PollSeconds: 60, MaxAgeSeconds: 180,
	}}}
}
func loadTrafficConfig(path string) (TrafficConfig, error) {
	c := defaultTrafficConfig()
	if path != "" {
		b, e := os.ReadFile(path)
		if e != nil {
			return c, e
		}
		if len(b) > 128_000 {
			return c, errors.New("traffic config too large")
		}
		d := json.NewDecoder(strings.NewReader(string(b)))
		d.DisallowUnknownFields()
		if e = d.Decode(&c); e != nil {
			return c, e
		}
		if d.Decode(new(any)) != io.EOF {
			return c, errors.New("trailing traffic config")
		}
	}
	if c.MaxMatchesPerSync == 0 {
		c.MaxMatchesPerSync = 50
	}
	if c.MaxMatchesPerSync < 1 || c.MaxMatchesPerSync > 500 {
		return c, errors.New("invalid traffic match limit")
	}
	ids := map[string]bool{}
	for i := range c.Providers {
		p := &c.Providers[i]
		if p.PollSeconds == 0 {
			p.PollSeconds = 60
		}
		if p.MaxAgeSeconds == 0 {
			p.MaxAgeSeconds = 180
		}
		if p.ID == "" || ids[p.ID] || len(p.Countries) == 0 || p.PollSeconds < 30 || p.MaxAgeSeconds < 60 || p.MaxAgeSeconds > 900 {
			return c, errors.New("invalid traffic provider")
		}
		ids[p.ID] = true
		if p.Enabled && trafficAdapters[p.Adapter] == nil {
			return c, fmt.Errorf("unsupported traffic adapter %q", p.Adapter)
		}
		for _, country := range p.Countries {
			if len(country) != 2 || strings.ToUpper(country) != country {
				return c, errors.New("invalid traffic country")
			}
		}
		for _, raw := range []string{p.EventsURL, p.SitesURL, p.MeasurementsURL} {
			if raw == "" {
				continue
			}
			u, e := url.Parse(raw)
			if e != nil || u.Scheme != "https" || u.Host == "" || u.User != nil || u.Fragment != "" {
				return c, errors.New("traffic feeds require HTTPS")
			}
		}
	}
	if c.BridgeURL != "" {
		u, e := url.Parse(c.BridgeURL)
		if e != nil || u.Host == "" || (u.Scheme != "http" && u.Scheme != "https") || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
			return c, errors.New("invalid traffic bridge URL")
		}
	}
	if c.EnableRouting && c.BridgeURL == "" {
		return c, errors.New("traffic routing requires bridgeURL")
	}
	return c, nil
}

type TrafficFeature struct {
	ID             string        `json:"id"`
	SourceID       string        `json:"sourceId"`
	Kind           string        `json:"kind"`
	Title          string        `json:"title"`
	Geometry       Geometry      `json:"geometry"`
	ObservedAt     time.Time     `json:"observedAt"`
	ExpiresAt      *time.Time    `json:"expiresAt,omitempty"`
	ValidFrom      *time.Time    `json:"validFrom,omitempty"`
	ValidUntil     *time.Time    `json:"validUntil,omitempty"`
	SpeedKph       *float64      `json:"speedKph,omitempty"`
	TravelSeconds  *float64      `json:"travelSeconds,omitempty"`
	NormalSeconds  *float64      `json:"normalSeconds,omitempty"`
	Congestion     string        `json:"congestion,omitempty"`
	Matched        bool          `json:"matched"`
	DirectionKnown bool          `json:"directionKnown"`
	Closed         bool          `json:"closed"`
	Points         []Point       `json:"-"`
	Version        string        `json:"-"`
	Edges          []trafficEdge `json:"-"`
	GraphStamp     int64         `json:"-"`
	RouteStart     *float64      `json:"routeStartMeters,omitempty"`
	RouteEnd       *float64      `json:"routeEndMeters,omitempty"`
}
type TrafficSourceStatus struct {
	ID            string     `json:"id"`
	Countries     []string   `json:"countries"`
	Attribution   string     `json:"attribution"`
	UpdatedAt     *time.Time `json:"updatedAt,omitempty"`
	FlowUpdatedAt *time.Time `json:"flowUpdatedAt,omitempty"`
	Stale         bool       `json:"stale"`
	Message       string     `json:"message,omitempty"`
	FeatureCount  int        `json:"featureCount"`
	MatchedCount  int        `json:"matchedCount"`
}
type trafficProviderSnapshot struct {
	Events, Flow     []TrafficFeature
	EventsAt, FlowAt time.Time
	Status           TrafficSourceStatus
}
type trafficService struct {
	config     TrafficConfig
	mu         sync.RWMutex
	snapshots  map[string]trafficProviderSnapshot
	providers  []trafficProvider
	matcher    *Valhalla
	bridge     *trafficBridge
	client     *http.Client
	now        func() time.Time
	matches    map[string]trafficMatch
	graphStamp int64
	wanted     map[string]time.Time
	slots      chan struct{}
	routes     map[string]trafficRouteContext
	routing    RoutingProvider
}
type trafficProvider interface {
	Configuration() TrafficProviderConfig
	Fetch(context.Context) (trafficProviderSnapshot, error)
}
type trafficProviderFactory func(TrafficProviderConfig,*http.Client)trafficProvider
var trafficAdapters=map[string]trafficProviderFactory{"ndw-datex3":func(c TrafficProviderConfig,h *http.Client)trafficProvider{return newNDWTrafficProvider(c,h)}}

func newTrafficService(c TrafficConfig, v *Valhalla) *trafficService {
	s := &trafficService{config: c, snapshots: map[string]trafficProviderSnapshot{}, matcher: v, now: time.Now, matches: map[string]trafficMatch{}, slots: make(chan struct{}, 2), client: &http.Client{Timeout: 15 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}
	for _, p := range c.Providers {
		if p.Enabled {
			if factory:=trafficAdapters[p.Adapter];factory!=nil{s.providers = append(s.providers, factory(p,s.client))}
		}
	}
	if c.EnableRouting {
		s.bridge = &trafficBridge{base: strings.TrimRight(c.BridgeURL, "/"), client: s.client, now: s.now}
	}
	return s
}
func (s *trafficService) run(ctx context.Context) {
	if !s.config.Enabled {
		return
	}
	var wg sync.WaitGroup
	for _, p := range s.providers {
		wg.Add(1)
		go func(p trafficProvider) {
			defer wg.Done()
			for {
				s.syncProvider(ctx, p)
				select {
				case <-ctx.Done():
					return
				case <-time.After(time.Duration(p.Configuration().PollSeconds) * time.Second):
				}
			}
		}(p)
	}
	wg.Wait()
}
func (s *trafficService) syncProvider(ctx context.Context, p trafficProvider) {
	c := p.Configuration()
	next, err := p.Fetch(ctx)
	s.mu.Lock()
	old := s.snapshots[c.ID]
	s.mu.Unlock()
	if err != nil {
		old.Status.Message = "Traffic provider unavailable; old data expires by observation/publication time."
		next = old
	} else {
		// Independent flow/events successes survive failure of the other feed.
		if next.EventsAt.IsZero() {
			next.Events = old.Events
			next.EventsAt = old.EventsAt
		}
		if next.FlowAt.IsZero() {
			next.Flow = old.Flow
			next.FlowAt = old.FlowAt
		}
		s.matchFlow(ctx, &next)
	}
	next.Status.ID = c.ID
	next.Status.Countries = c.Countries
	next.Status.Attribution = c.Attribution
	s.mu.Lock()
	s.snapshots[c.ID] = next
	s.mu.Unlock()
	if s.bridge != nil {
		s.publishBridge(ctx)
	}
}
func (s *trafficService) features() ([]TrafficFeature, []TrafficSourceStatus) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	features := []TrafficFeature{}
	statuses := []TrafficSourceStatus{}
	now := s.now()
	for _, c := range s.config.Providers {
		if !c.Enabled {
			continue
		}
		p := s.snapshots[c.ID]
		st := p.Status
		st.ID = c.ID
		st.Countries = c.Countries
		st.Attribution = c.Attribution
		st.Stale = p.EventsAt.IsZero() || now.Sub(p.EventsAt) > time.Duration(c.MaxAgeSeconds)*time.Second || p.EventsAt.After(now.Add(time.Minute))
		if !p.EventsAt.IsZero() {
			t := p.EventsAt
			st.UpdatedAt = &t
		}
		if !p.FlowAt.IsZero() {
			t := p.FlowAt
			st.FlowUpdatedAt = &t
		}
		for _, f := range p.Events {
			if f.GraphStamp != s.graphStamp {
				f.Matched = false
				f.Edges = nil
			}
			if !st.Stale && eventActive(f, now) {
				expires := p.EventsAt.Add(time.Duration(c.MaxAgeSeconds) * time.Second)
				if f.ValidUntil != nil && f.ValidUntil.Before(expires) {
					expires = *f.ValidUntil
				}
				f.ExpiresAt = &expires
				features = append(features, f)
			}
		}
		for _, f := range p.Flow {
			if f.GraphStamp != s.graphStamp {
				f.Matched = false
				f.Edges = nil
			}
			age := now.Sub(f.ObservedAt)
			if age >= -time.Minute && age <= time.Duration(c.MaxAgeSeconds)*time.Second {
				expires := f.ObservedAt.Add(time.Duration(c.MaxAgeSeconds) * time.Second)
				f.ExpiresAt = &expires
				features = append(features, f)
			}
		}
		st.FeatureCount = 0
		st.MatchedCount = 0
		for _, f := range features {
			if f.SourceID == c.ID {
				st.FeatureCount++
				if f.Matched {
					st.MatchedCount++
				}
			}
		}
		statuses = append(statuses, st)
	}
	sort.Slice(statuses, func(i, j int) bool { return statuses[i].ID < statuses[j].ID })
	sort.Slice(features, func(i, j int) bool { return features[i].ID < features[j].ID })
	return features, statuses
}
func eventActive(f TrafficFeature, now time.Time) bool {
	return (f.ValidFrom == nil || !now.Before(*f.ValidFrom)) && (f.ValidUntil == nil || now.Before(*f.ValidUntil))
}
func (s *trafficService) capability() map[string]any {
	_, sources := s.features()
	return map[string]any{"enabled": s.config.Enabled, "sources": sources, "routingEnabled": s.liveReady(), "mapEnabled": s.config.Enabled, "pollSeconds": 60, "alternativeCheckSeconds": 300, "offerSeconds": 15}
}

type TrafficRequest struct {
	BBox  *CameraBBox       `json:"bbox"`
	Route *CameraRouteQuery `json:"route,omitempty"`
	Token string            `json:"token,omitempty"`
}
type TrafficResponse struct {
	GeneratedAt    time.Time             `json:"generatedAt"`
	Sources        []TrafficSourceStatus `json:"sources"`
	Features       []TrafficFeature      `json:"features"`
	RoutingEnabled bool                  `json:"routingEnabled"`
	Truncated      bool                  `json:"truncated"`
}

func (s *trafficService) serveHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	fail := func(code int) {
		w.WriteHeader(code)
		_ = json.NewEncoder(w).Encode(map[string]any{"error": apiError("invalid_request")})
	}
	media, _, mediaErr := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if mediaErr != nil || media != "application/json" {
		fail(415)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 256_000)
	defer r.Body.Close()
	d := json.NewDecoder(r.Body)
	d.DisallowUnknownFields()
	var q TrafficRequest
	if d.Decode(&q) != nil || d.Decode(new(any)) != io.EOF {
		fail(400)
		return
	}
	points, err := (CameraRequest{BBox: q.BBox, Route: q.Route}).validate()
	if err != nil {
		fail(400)
		return
	}
	corridor := 150.0
	routeIDs := map[uint64]bool{}
	if q.Route != nil {
		corridor = q.Route.CorridorMeters
	}
	if q.Token != "" {
		s.mu.RLock()
		entry, exists := s.routes[q.Token]
		s.mu.RUnlock()
		if !exists || !entry.Expires.After(s.now()) {
			w.WriteHeader(410)
			return
		}
		points, err = decodePolyline(entry.Route.Geometry.Data)
		if err != nil {
			fail(400)
			return
		}
		s.mu.RLock()
		sameGraph := entry.Stamp == s.graphStamp
		s.mu.RUnlock()
		if sameGraph {
			for _, edge := range entry.Edges {
				routeIDs[edge.ID] = true
			}
		}
	}
	all, sources := s.features()
	// Spend the response budget on events first, then drawable congestion.
	// Normal/unmatched flow remains available to ingestion and route costing,
	// but must not crowd useful map features out of the bounded response.
	sort.SliceStable(all, func(i, j int) bool {
		return all[i].Kind != "flow" && all[j].Kind == "flow"
	})
	out := TrafficResponse{GeneratedAt: s.now().UTC(), Sources: sources, Features: []TrafficFeature{}, RoutingEnabled: s.liveReady()}
	b := q.BBox
	geometryBytes := 0
	deadline := time.Now().Add(2 * time.Second)
	cumulative := cameraCumulative(points)
	for _, f := range all {
		if f.Kind == "flow" && f.Congestion != "slow" && f.Congestion != "heavy" {
			continue
		}
		if time.Now().After(deadline) {
			out.Truncated = true
			break
		}
		inside := b.intersects(f.Points)
		if !inside && len(points) > 1 {
			for _, p := range f.Points {
				for i := 1; i < len(points); i++ {
					if i%256 == 0 && time.Now().After(deadline) {
						out.Truncated = true
						break
					}
					_, lateral := projectCamera(p, points[i-1], points[i])
					if lateral <= corridor {
						inside = true
						break
					}
				}
				if inside {
					break
				}
				if out.Truncated {
					break
				}
			}
		}
		if inside {
			if !f.Matched && f.Kind == "flow" {
				s.mu.Lock()
				if s.wanted == nil {
					s.wanted = map[string]time.Time{}
				}
				if len(s.wanted) < 2000 {
					s.wanted[f.ID] = s.now()
				}
				s.mu.Unlock()
			}
			if f.Kind == "flow" && !f.Matched {
				continue
			}
			matchedIDs, totalIDs := 0.0, 0.0
			for _, edge := range f.Edges {
				totalIDs += edge.Length
				if routeIDs[edge.ID] {
					matchedIDs += edge.Length
				}
			}
			if len(points) > 1 && len(f.Points) > 1 && f.Matched && totalIDs > 0 && matchedIDs/totalIDs >= 0.8 {
				a := projectOnRoute(f.Points[0], points, cumulative)
				b := projectOnRoute(f.Points[len(f.Points)-1], points, cumulative)
				if a.lateral < 30 && b.lateral < 30 && b.along > a.along {
					start, end := a.along, b.along
					f.RouteStart = &start
					f.RouteEnd = &end
				}
			}
			geometryBytes += len(f.Geometry.Data)
			if len(out.Features) == 1500 || geometryBytes > 2_000_000 {
				out.Truncated = true
				break
			}
			out.Features = append(out.Features, f)
		}
	}
	_ = json.NewEncoder(w).Encode(out)
}
