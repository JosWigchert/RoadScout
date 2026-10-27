package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"math"
	"mime"
	"net/http"
	"sort"
	"sync"
	"time"
)

const (
	weatherRouteTokenTTL           = 15 * time.Minute
	weatherDistanceSpacingMeters   = 2000.0
	weatherIntervalSpacingSeconds  = 300.0
	weatherMaxSamples              = 400
	weatherMaxRouteTokens          = 512
	weatherMaxCacheEntries         = 1024
	weatherRainProbabilityPercent  = 30
	weatherRainIntensityMmPerHour  = 0.1
	weatherRecommendationRoofDown  = "roof_down"
	weatherRecommendationRainRisk  = "rain_risk"
	weatherRecommendationUnavail   = "unavailable"
	weatherRequestBodyLimitBytes   = 1024
	weatherProviderRequestDeadline = 12 * time.Second
)

type WeatherCoordinate struct {
	Latitude  float64 `json:"latitude"`
	Longitude float64 `json:"longitude"`
}
type WeatherSummary struct {
	MaxProbabilityPercent int               `json:"maxProbabilityPercent"`
	MaxIntensityMmPerHour float64           `json:"maxIntensityMmPerHour"`
	WorstAt               time.Time         `json:"worstAt"`
	WorstCoordinate       WeatherCoordinate `json:"worstCoordinate"`
	SampleCount           int               `json:"sampleCount"`
	RainRiskSampleCount   int               `json:"rainRiskSampleCount"`
}
type WeatherSegmentGeometry struct {
	Encoding string `json:"encoding"`
	Data     string `json:"data"`
}
type WeatherSegment struct {
	StartMeters        float64                `json:"startMeters"`
	EndMeters          float64                `json:"endMeters"`
	StartAt            time.Time              `json:"startAt"`
	EndAt              time.Time              `json:"endAt"`
	ProbabilityPercent int                    `json:"probabilityPercent"`
	IntensityMmPerHour float64                `json:"intensityMmPerHour"`
	Geometry           WeatherSegmentGeometry `json:"geometry"`
}
type WeatherResponse struct {
	RouteToken     string              `json:"routeToken"`
	GeneratedAt    time.Time           `json:"generatedAt"`
	DepartureAt    time.Time           `json:"departureAt"`
	ExpiresAt      time.Time           `json:"expiresAt"`
	Provider       WeatherProviderInfo `json:"provider"`
	Recommendation string              `json:"recommendation"`
	Summary        *WeatherSummary     `json:"summary,omitempty"`
	Segments       []WeatherSegment    `json:"segments"`
	Warnings       []Warning           `json:"warnings"`
}

type WeatherRequest struct {
	RouteToken  string    `json:"routeToken"`
	DepartureAt time.Time `json:"departureAt"`
}

func (q *WeatherRequest) UnmarshalJSON(data []byte) error {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		return err
	}
	for _, key := range []string{"routeToken", "departureAt"} {
		if len(fields[key]) == 0 || string(fields[key]) == "null" {
			return apiError("invalid_request")
		}
	}
	type plain WeatherRequest
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode((*plain)(q)); err != nil {
		return apiError("invalid_request")
	}
	return nil
}

type routeTokenEntry struct {
	Token     string
	Geometry  string
	Duration  float64
	Anchors   []Anchor
	ExpiresAt time.Time
}

type routeTokenStore struct {
	mu      sync.Mutex
	now     func() time.Time
	ttl     time.Duration
	max     int
	entries map[string]routeTokenEntry
	order   []string
}

func newRouteTokenStore(now func() time.Time) *routeTokenStore {
	return &routeTokenStore{now: now, ttl: weatherRouteTokenTTL, max: weatherMaxRouteTokens, entries: map[string]routeTokenEntry{}}
}

func (s *routeTokenStore) add(entry routeTokenEntry) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	for token, existing := range s.entries {
		if !existing.ExpiresAt.After(now) {
			delete(s.entries, token)
		}
	}
	s.entries[entry.Token] = entry
	s.order = append(s.order, entry.Token)
	for len(s.entries) > s.max && len(s.order) > 0 {
		oldest := s.order[0]
		s.order = s.order[1:]
		delete(s.entries, oldest)
	}
	if len(s.order) > 2*s.max {
		s.order = s.order[len(s.order)-s.max:]
	}
}

func (s *routeTokenStore) get(token string) (routeTokenEntry, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	entry, ok := s.entries[token]
	if !ok {
		return routeTokenEntry{}, false
	}
	if !entry.ExpiresAt.After(s.now()) {
		delete(s.entries, token)
		return routeTokenEntry{}, false
	}
	return entry, true
}

func (s *routeTokenStore) count() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.entries)
}

type weatherCacheEntry struct {
	value     WeatherResponse
	expiresAt time.Time
}
type weatherCache struct {
	mu      sync.Mutex
	now     func() time.Time
	ttl     time.Duration
	max     int
	entries map[string]weatherCacheEntry
	order   []string
}

func newWeatherCache(now func() time.Time, ttl time.Duration) *weatherCache {
	return &weatherCache{now: now, ttl: ttl, max: weatherMaxCacheEntries, entries: map[string]weatherCacheEntry{}}
}
func (c *weatherCache) get(key string) (WeatherResponse, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	entry, ok := c.entries[key]
	if !ok || !entry.expiresAt.After(c.now()) {
		delete(c.entries, key)
		return WeatherResponse{}, false
	}
	return entry.value, true
}
func (c *weatherCache) set(key string, value WeatherResponse) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if _, exists := c.entries[key]; !exists {
		c.order = append(c.order, key)
	}
	c.entries[key] = weatherCacheEntry{value: value, expiresAt: c.now().Add(c.ttl)}
	for len(c.entries) > c.max && len(c.order) > 0 {
		oldest := c.order[0]
		c.order = c.order[1:]
		delete(c.entries, oldest)
	}
	if len(c.order) > 2*c.max {
		c.order = c.order[len(c.order)-c.max:]
	}
}

type weatherService struct {
	providers []weatherProvider
	tokens    *routeTokenStore
	cache     *weatherCache
	now       func() time.Time
	cacheTTL  time.Duration
	slots     chan struct{}
}

func newWeatherService(providers []weatherProvider, cacheTTL time.Duration, now func() time.Time) *weatherService {
	if now == nil {
		now = time.Now
	}
	return &weatherService{providers: providers, tokens: newRouteTokenStore(now), cache: newWeatherCache(now, cacheTTL), now: now, cacheTTL: cacheTTL, slots: make(chan struct{}, 4)}
}

func newWeatherToken() (string, error) {
	var raw [32]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(raw[:]), nil
}

func validWeatherToken(token string) bool {
	if len(token) < 16 || len(token) > 256 {
		return false
	}
	for _, c := range token {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
			return false
		}
	}
	return true
}

// register stores only the encoded route geometry, duration and timing anchors,
// so weather refreshes never resend route geometry and the store stays bounded.
func (s *weatherService) register(route Route) (string, time.Time) {
	return s.registerRoute(route.Geometry.Data, route.Summary.Duration, route.Timing.Anchors)
}
func (s *weatherService) registerRoute(geometry string, duration float64, anchors []Anchor) (string, time.Time) {
	token, err := newWeatherToken()
	if err != nil {
		return "", time.Time{}
	}
	expiresAt := s.now().UTC().Truncate(time.Second).Add(weatherRouteTokenTTL)
	s.tokens.add(routeTokenEntry{Token: token, Geometry: geometry, Duration: duration, Anchors: append([]Anchor(nil), anchors...), ExpiresAt: expiresAt})
	return token, expiresAt
}

func (s *weatherService) capability() map[string]any {
	info := s.providers[0].Info()
	return map[string]any{
		"provider":             info.ID,
		"coverage":             info.Coverage,
		"license":              info.License,
		"attribution":          info.Attribution,
		"routeTokenTTLSeconds": int(weatherRouteTokenTTL.Seconds()),
		"cacheTTLSeconds":      int(s.cacheTTL.Seconds()),
		"sampling":             map[string]any{"distanceMeters": weatherDistanceSpacingMeters, "intervalSeconds": weatherIntervalSpacingSeconds, "maxSamples": weatherMaxSamples},
		"rainRisk":             map[string]any{"probabilityPercent": weatherRainProbabilityPercent, "intensityMmPerHour": weatherRainIntensityMmPerHour},
	}
}

func (s *weatherService) serveHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	fail := func(status int, code string) {
		w.WriteHeader(status)
		_ = json.NewEncoder(w).Encode(map[string]any{"error": apiError(code)})
	}
	media, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || media != "application/json" {
		fail(415, "invalid_request")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, weatherRequestBodyLimitBytes)
	defer r.Body.Close()
	decoder := json.NewDecoder(r.Body)
	var request WeatherRequest
	if err := decoder.Decode(&request); err != nil {
		if _, ok := err.(*http.MaxBytesError); ok {
			fail(413, "limit_exceeded")
		} else {
			fail(400, "invalid_request")
		}
		return
	}
	if decoder.Decode(new(any)) != io.EOF {
		fail(400, "invalid_request")
		return
	}
	if !validWeatherToken(request.RouteToken) || request.DepartureAt.IsZero() {
		fail(400, "invalid_request")
		return
	}
	entry, ok := s.tokens.get(request.RouteToken)
	if !ok {
		fail(410, "weather_token_expired")
		return
	}
	select {
	case s.slots <- struct{}{}:
		defer func() { <-s.slots }()
	default:
		w.Header().Set("Retry-After", "5")
		fail(429, "busy")
		return
	}
	departureAt := request.DepartureAt.UTC().Truncate(time.Second)
	cacheKey := entry.Token + "|" + departureAt.Format(time.RFC3339)
	if cached, hit := s.cache.get(cacheKey); hit {
		_ = json.NewEncoder(w).Encode(cached)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), weatherProviderRequestDeadline)
	defer cancel()
	response, err := s.analyze(ctx, entry, departureAt)
	if err != nil {
		var apiErr *APIError
		if errors.As(err, &apiErr) {
			status := 503
			if apiErr.Code == "invalid_request" {
				status = 400
			} else if apiErr.Code == "weather_token_expired" {
				status = 410
			}
			fail(status, apiErr.Code)
			return
		}
		if r.Context().Err() != nil {
			return
		}
		fail(503, "weather_unavailable")
		return
	}
	s.cache.set(cacheKey, response)
	_ = json.NewEncoder(w).Encode(response)
}

// analyze samples the stored route, resolves provider forecasts and produces the
// recommendation, worst summary and contiguous rain-risk segments.
func (s *weatherService) analyze(ctx context.Context, entry routeTokenEntry, departureAt time.Time) (WeatherResponse, error) {
	points, err := decodePolyline(entry.Geometry)
	if err != nil || len(points) < 2 {
		return WeatherResponse{}, apiError("invalid_request")
	}
	cumulative := cameraCumulative(points)
	samples := sampleRoute(points, cumulative, entry.Duration, entry.Anchors, departureAt)
	if len(samples) == 0 {
		return WeatherResponse{}, apiError("weather_unavailable")
	}
	forecasts := make([]sampleForecast, len(samples))
	warnings := []Warning{}
	succeeded := false
	for _, provider := range s.providers {
		results, providerErr := provider.Forecast(ctx, samples)
		if providerErr != nil {
			if ctx.Err() != nil {
				return WeatherResponse{}, ctx.Err()
			}
			warnings = append(warnings, Warning{"weather_provider_error", provider.Info().Name + " did not return a forecast."})
			continue
		}
		if len(results) != len(samples) {
			warnings = append(warnings, Warning{"weather_provider_error", provider.Info().Name + " returned an incomplete forecast."})
			continue
		}
		succeeded = true
		for i := range forecasts {
			forecasts[i] = worstForecast(forecasts[i], results[i])
		}
	}
	if !succeeded {
		return WeatherResponse{}, apiError("weather_unavailable")
	}
	unavailable := 0
	for _, forecast := range forecasts {
		if !forecast.Available {
			unavailable++
		}
	}
	info := s.providers[0].Info()
	if unavailable > 0 {
		warnings = append(warnings, Warning{"weather_samples_missing", "Some forecast samples are missing or outside provider coverage; no dry guarantee."})
	}
	if unavailable > 0 {
		return s.buildResponse(entry, departureAt, info, weatherRecommendationUnavail, nil, []WeatherSegment{}, warnings), nil
	}
	risk := make([]bool, len(samples))
	rainRiskCount := 0
	for i, forecast := range forecasts {
		if forecast.Available && forecast.ProbabilityPercent >= weatherRainProbabilityPercent && forecast.IntensityMmPerHour >= weatherRainIntensityMmPerHour {
			risk[i] = true
			rainRiskCount++
		}
	}
	recommendation := weatherRecommendationRoofDown
	if rainRiskCount > 0 {
		recommendation = weatherRecommendationRainRisk
	}
	summary := &WeatherSummary{SampleCount: len(samples), RainRiskSampleCount: rainRiskCount}
	worst := -1
	for i, forecast := range forecasts {
		if !forecast.Available {
			continue
		}
		if worst < 0 || forecast.IntensityMmPerHour > forecasts[worst].IntensityMmPerHour ||
			(forecast.IntensityMmPerHour == forecasts[worst].IntensityMmPerHour && forecast.ProbabilityPercent > forecasts[worst].ProbabilityPercent) {
			worst = i
		}
	}
	if worst >= 0 {
		summary.MaxProbabilityPercent = forecasts[worst].ProbabilityPercent
		summary.MaxIntensityMmPerHour = forecasts[worst].IntensityMmPerHour
		summary.WorstAt = samples[worst].At
		summary.WorstCoordinate = WeatherCoordinate{samples[worst].Coordinate.Latitude, samples[worst].Coordinate.Longitude}
	}
	segments := []WeatherSegment{}
	for i := 0; i < len(risk); {
		if !risk[i] {
			i++
			continue
		}
		j := i
		for j+1 < len(risk) && risk[j+1] {
			j++
		}
		startMeters := samples[i].Meters
		if i > 0 {
			startMeters = (samples[i-1].Meters + samples[i].Meters) / 2
		}
		endMeters := samples[j].Meters
		if j+1 < len(samples) {
			endMeters = (samples[j].Meters + samples[j+1].Meters) / 2
		}
		probability, intensity := 0, 0.0
		for k := i; k <= j; k++ {
			if forecasts[k].ProbabilityPercent > probability {
				probability = forecasts[k].ProbabilityPercent
			}
			if forecasts[k].IntensityMmPerHour > intensity {
				intensity = forecasts[k].IntensityMmPerHour
			}
		}
		slice := sliceGeometry(points, cumulative, startMeters, endMeters)
		segments = append(segments, WeatherSegment{
			StartMeters:        startMeters,
			EndMeters:          endMeters,
			StartAt:            etaAt(cumulative, entry.Anchors, entry.Duration, departureAt, startMeters),
			EndAt:              etaAt(cumulative, entry.Anchors, entry.Duration, departureAt, endMeters),
			ProbabilityPercent: probability,
			IntensityMmPerHour: intensity,
			Geometry:           WeatherSegmentGeometry{Encoding: "polyline6", Data: encodePolyline(slice)},
		})
		i = j + 1
	}
	return s.buildResponse(entry, departureAt, info, recommendation, summary, segments, warnings), nil
}

func (s *weatherService) buildResponse(entry routeTokenEntry, departureAt time.Time, info WeatherProviderInfo, recommendation string, summary *WeatherSummary, segments []WeatherSegment, warnings []Warning) WeatherResponse {
	generatedAt := s.now().UTC().Truncate(time.Second)
	expiresAt := generatedAt.Add(s.cacheTTL)
	if entry.ExpiresAt.Before(expiresAt) {
		expiresAt = entry.ExpiresAt
	}
	if warnings == nil {
		warnings = []Warning{}
	}
	return WeatherResponse{
		RouteToken:     entry.Token,
		GeneratedAt:    generatedAt,
		DepartureAt:    departureAt,
		ExpiresAt:      expiresAt,
		Provider:       info,
		Recommendation: recommendation,
		Summary:        summary,
		Segments:       segments,
		Warnings:       warnings,
	}
}

// sampleRoute chooses spacing = max(2 km, 5 min x average speed, length/400),
// always includes start and end, and caps the total at weatherMaxSamples while
// still covering the whole route.
func sampleRoute(points []Point, cumulative []float64, duration float64, anchors []Anchor, departureAt time.Time) []weatherSample {
	if len(points) < 2 || len(cumulative) != len(points) {
		return nil
	}
	total := cumulative[len(cumulative)-1]
	if total <= 0 {
		return nil
	}
	averageSpeed := 0.0
	if duration > 0 {
		averageSpeed = total / duration
	}
	spacing := math.Max(weatherDistanceSpacingMeters, weatherIntervalSpacingSeconds*averageSpeed)
	spacing = math.Max(spacing, total/float64(weatherMaxSamples))
	count := int(math.Floor(total/spacing)) + 1
	if count > weatherMaxSamples {
		count = weatherMaxSamples
		spacing = total / float64(count-1)
	}
	if count < 2 {
		count = 2
		spacing = total
	}
	samples := make([]weatherSample, count)
	for i := 0; i < count; i++ {
		meters := float64(i) * spacing
		if i == count-1 {
			meters = total
		}
		coordinate := pointAtDistance(points, cumulative, meters)
		at := departureAt.Add(time.Duration(elapsedAtDistance(cumulative, anchors, duration, meters) * float64(time.Second)))
		samples[i] = weatherSample{Coordinate: coordinate, At: at.UTC().Truncate(time.Second), Meters: meters, Index: i}
	}
	return samples
}

func pointAtDistance(points []Point, cumulative []float64, meters float64) Point {
	total := cumulative[len(cumulative)-1]
	if meters <= 0 {
		return points[0]
	}
	if meters >= total {
		return points[len(points)-1]
	}
	index := sort.Search(len(cumulative), func(i int) bool { return cumulative[i] >= meters })
	if index <= 0 {
		return points[0]
	}
	if index >= len(points) {
		return points[len(points)-1]
	}
	span := cumulative[index] - cumulative[index-1]
	fraction := 0.0
	if span > 0 {
		fraction = (meters - cumulative[index-1]) / span
	}
	return Point{
		Latitude:  points[index-1].Latitude + (points[index].Latitude-points[index-1].Latitude)*fraction,
		Longitude: points[index-1].Longitude + (points[index].Longitude-points[index-1].Longitude)*fraction,
	}
}

// elapsedAtDistance mirrors the iOS route-card estimate: timing anchors when
// available, otherwise linear distance interpolation.
func elapsedAtDistance(cumulative []float64, anchors []Anchor, duration, meters float64) float64 {
	length := cumulative[len(cumulative)-1]
	clamp := func(value float64) float64 { return math.Min(1, math.Max(0, value)) }
	if len(anchors) < 2 || length <= 0 {
		return duration * clamp(meters/length)
	}
	for i := 0; i+1 < len(anchors); i++ {
		a, b := anchors[i], anchors[i+1]
		if a.Index < 0 || b.Index >= len(cumulative) || b.Index <= a.Index {
			continue
		}
		start, end := cumulative[a.Index], cumulative[b.Index]
		if meters <= end && end > start {
			return a.Elapsed + (b.Elapsed-a.Elapsed)*clamp((meters-start)/(end-start))
		}
	}
	return duration
}

func etaAt(cumulative []float64, anchors []Anchor, duration float64, departureAt time.Time, meters float64) time.Time {
	return departureAt.Add(time.Duration(elapsedAtDistance(cumulative, anchors, duration, meters) * float64(time.Second))).UTC().Truncate(time.Second)
}

// sliceGeometry clips the route between two along-route distances, always
// returning at least two distinct points.
func sliceGeometry(points []Point, cumulative []float64, startMeters, endMeters float64) []Point {
	total := cumulative[len(cumulative)-1]
	if startMeters < 0 {
		startMeters = 0
	}
	if endMeters > total {
		endMeters = total
	}
	if endMeters <= startMeters {
		endMeters = math.Min(total, startMeters+1)
	}
	if endMeters <= startMeters {
		return []Point{pointAtDistance(points, cumulative, startMeters), pointAtDistance(points, cumulative, endMeters)}
	}
	result := []Point{pointAtDistance(points, cumulative, startMeters)}
	for i := 0; i < len(points); i++ {
		if cumulative[i] > startMeters && cumulative[i] < endMeters {
			if distance(result[len(result)-1], points[i]) > 0.001 {
				result = append(result, points[i])
			}
		}
	}
	end := pointAtDistance(points, cumulative, endMeters)
	if distance(result[len(result)-1], end) > 0.001 {
		result = append(result, end)
	}
	if len(result) < 2 {
		result = append(result, points[len(points)-1])
	}
	return result
}
