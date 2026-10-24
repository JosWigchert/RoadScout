package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"math"
	"net/http"
	"sort"
	"sync"
)

// These objectives compare a bounded candidate pool; they do not change graph-edge costing.
type RouteExperiment struct {
	RequestedObjective   string  `json:"requestedObjective"`
	EffectiveObjective   string  `json:"effectiveObjective"`
	Status               string  `json:"status"`
	Method               string  `json:"method"`
	BaselineDuration     float64 `json:"baselineDurationSeconds"`
	ExtraDurationPercent float64 `json:"extraDurationPercent"`
	DetourLimitPercent   int     `json:"detourLimitPercent"`
	BendCount            int     `json:"bendCount"`
	BendsPerKilometer    float64 `json:"bendsPerKilometer"`
	CountrysideShare     float64 `json:"countrysideShare"`
}

type roadEdge struct {
	WayID   int64  `json:"way_id"`
	Begin   int    `json:"begin_shape_index"`
	End     int    `json:"end_shape_index"`
	Class   string `json:"road_class"`
	Surface string `json:"surface"`
	Use     string `json:"use"`
	Density *int   `json:"density"`
}
type roadAttributes struct {
	Shape string     `json:"shape"`
	Edges []roadEdge `json:"edges"`
}
type roadAttributeProvider interface {
	attributesFor(context.Context, Route) (roadAttributes, error)
}

func (v *Valhalla) attributesFor(ctx context.Context, route Route) (roadAttributes, error) {
	payload := map[string]any{"encoded_polyline": route.Geometry.Data, "costing": "auto", "shape_match": "edge_walk",
		"filters": map[string]any{"action": "include", "attributes": []string{"shape", "edge.way_id", "edge.road_class", "edge.surface", "edge.use", "edge.density", "edge.begin_shape_index", "edge.end_shape_index"}}}
	data, _ := json.Marshal(payload)
	req, _ := http.NewRequestWithContext(ctx, "POST", v.BaseURL+"/trace_attributes", bytes.NewReader(data))
	req.Header.Set("Content-Type", "application/json")
	response, err := v.Client.Do(req)
	if err != nil {
		return roadAttributes{}, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return roadAttributes{}, apiError("upstream_unavailable")
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, 8_000_001))
	if err != nil || len(body) > 8_000_000 {
		return roadAttributes{}, apiError("invalid_upstream_response")
	}
	var result roadAttributes
	if json.Unmarshal(body, &result) != nil || result.Shape != route.Geometry.Data || len(result.Edges) == 0 {
		return roadAttributes{}, apiError("invalid_upstream_response")
	}
	return result, nil
}

type experimentalRouter struct {
	base       RoutingProvider
	attributes roadAttributeProvider
}

func (r *experimentalRouter) Ready(ctx context.Context) error { return r.base.Ready(ctx) }

type routeMetrics struct {
	bends                                               int
	density, countryside, eligibleMeters, unpavedMeters float64
}
type analyzedCandidate struct {
	route   Route
	metrics routeMetrics
	valid   bool
}

func (r *experimentalRouter) Routes(ctx context.Context, request RouteRequest) ([]Route, []Warning, error) {
	if request.Objective == "fastest" {
		return r.base.Routes(ctx, request)
	}
	if request.Objective != "scenic" && request.Objective != "more_corners" {
		return nil, nil, apiError("unsupported_option")
	}
	if len(request.Waypoints) != 2 {
		return nil, nil, apiError("unsupported_option")
	}
	budget := 30
	if request.MaxExtraDurationPercent != nil {
		budget = *request.MaxExtraDurationPercent
	}
	baseRequest := request
	baseRequest.Objective, baseRequest.Alternatives, baseRequest.MaxExtraDurationPercent = "fastest", 2, nil
	baselineRoutes, warnings, err := r.base.Routes(ctx, baseRequest)
	if err != nil {
		return nil, nil, err
	}
	if len(baselineRoutes) == 0 {
		return nil, nil, apiError("invalid_upstream_response")
	}
	fastest := baselineRoutes[0]
	for _, route := range baselineRoutes {
		if route.Summary.Duration < fastest.Summary.Duration {
			fastest = route
		}
	}
	if fastest.Summary.Duration <= 0 {
		return nil, nil, apiError("invalid_upstream_response")
	}
	if fastest.Summary.Distance > 250_000 {
		return nil, nil, apiError("limit_exceeded")
	}
	countryRequest := baseRequest
	countryRequest.Preferences.Motorways = "avoid"
	countryRoutes, countryWarnings, countryError := r.base.Routes(ctx, countryRequest)
	warnings = append(warnings, countryWarnings...)
	if ctx.Err() != nil {
		return nil, nil, ctx.Err()
	}
	if countryError != nil {
		warnings = append(warnings, Warning{"experimental_pool_incomplete", "Additional candidates were unavailable."})
	}
	pool := []Route{fastest}
	seen := map[string]bool{fastest.Geometry.Data: true}
	for _, route := range append(baselineRoutes, countryRoutes...) {
		if !seen[route.Geometry.Data] && route.Summary.Duration <= fastest.Summary.Duration*(1+float64(budget)/100) {
			seen[route.Geometry.Data] = true
			pool = append(pool, route)
		}
		if len(pool) >= 6 {
			break
		}
	}
	analyzed := make([]analyzedCandidate, len(pool))
	var group sync.WaitGroup
	slots := make(chan struct{}, 2)
	for i, route := range pool {
		group.Add(1)
		go func(index int, route Route) {
			defer group.Done()
			analyzed[index].route = route
			select {
			case slots <- struct{}{}:
			case <-ctx.Done():
				return
			}
			defer func() { <-slots }()
			attributes, err := r.attributes.attributesFor(ctx, route)
			if err != nil {
				return
			}
			metrics, err := analyzeRoadRoute(route, attributes)
			if err == nil {
				analyzed[index].metrics, analyzed[index].valid = metrics, true
			}
		}(i, route)
	}
	group.Wait()
	if ctx.Err() != nil {
		return nil, nil, ctx.Err()
	}
	status := "no_improvement"
	if !analyzed[0].valid {
		status = "metadata_unavailable"
	}
	score := func(candidate analyzedCandidate) float64 {
		if request.Objective == "scenic" {
			return candidate.metrics.countryside
		}
		return candidate.metrics.density
	}
	improves := func(candidate analyzedCandidate) bool {
		if !analyzed[0].valid || !candidate.valid || candidate.metrics.eligibleMeters < 500 || candidate.metrics.unpavedMeters > 100 {
			return false
		}
		if request.Objective == "scenic" {
			return candidate.metrics.countryside > analyzed[0].metrics.countryside+0.02
		}
		return candidate.metrics.bends > analyzed[0].metrics.bends && candidate.metrics.density > analyzed[0].metrics.density+0.05
	}
	best := -1
	for i := 1; i < len(analyzed); i++ {
		if improves(analyzed[i]) && (best < 0 || score(analyzed[i]) > score(analyzed[best]) ||
			(score(analyzed[i]) == score(analyzed[best]) && analyzed[i].route.Summary.Duration < analyzed[best].route.Summary.Duration)) {
			best = i
		}
	}
	indices := []int{0}
	if best >= 0 {
		indices, status = []int{best, 0}, "improved"
	}
	rest := make([]int, 0, len(analyzed))
	for i := 1; i < len(analyzed); i++ {
		if i != best {
			rest = append(rest, i)
		}
	}
	sort.SliceStable(rest, func(i, j int) bool { return score(analyzed[rest[i]]) > score(analyzed[rest[j]]) })
	indices = append(indices, rest...)
	if status != "improved" {
		warnings = append(warnings, Warning{"experimental_" + status, "No verified improvement within the detour budget; Fastest is shown."})
	}
	output := make([]Route, 0, request.Alternatives+1)
	for _, i := range indices {
		candidate := analyzed[i]
		route := candidate.route
		route.Objective = "fastest"
		if improves(candidate) {
			route.Objective = request.Objective
		}
		route.Experiment = &RouteExperiment{RequestedObjective: request.Objective, EffectiveObjective: route.Objective,
			Status: status, Method: "candidate_reranking_v1", BaselineDuration: fastest.Summary.Duration,
			ExtraDurationPercent: math.Min(float64(budget), math.Max(0, (route.Summary.Duration/fastest.Summary.Duration-1)*100)), DetourLimitPercent: budget,
			BendCount: candidate.metrics.bends, BendsPerKilometer: candidate.metrics.density, CountrysideShare: candidate.metrics.countryside}
		output = append(output, route)
		if len(output) >= request.Alternatives+1 {
			break
		}
	}
	return output, warnings, nil
}

type distanceInterval struct{ begin, end float64 }

func eligibleRoad(edge roadEdge) bool {
	if edge.Density == nil || *edge.Density < 0 || *edge.Density > 8 || edge.Use != "road" {
		return false
	}
	if edge.Surface != "paved" && edge.Surface != "paved_smooth" && edge.Surface != "paved_rough" {
		return false
	}
	switch edge.Class {
	case "primary", "secondary", "tertiary", "unclassified":
		return true
	}
	return false
}

func pavedSurface(surface string) bool {
	return surface == "paved" || surface == "paved_smooth" || surface == "paved_rough"
}

func analyzeRoadRoute(route Route, attributes roadAttributes) (routeMetrics, error) {
	bad := apiError("invalid_upstream_response")
	points, err := decodePolyline(route.Geometry.Data)
	if err != nil || len(points) < 2 || attributes.Shape != route.Geometry.Data || len(attributes.Edges) == 0 {
		return routeMetrics{}, bad
	}
	cumulative := make([]float64, len(points))
	for i := 1; i < len(points); i++ {
		cumulative[i] = cumulative[i-1] + distance(points[i-1], points[i])
	}
	total := cumulative[len(cumulative)-1]
	if total <= 0 {
		return routeMetrics{}, bad
	}
	allowed := make([]bool, len(points)-1)
	paved := make([]bool, len(points)-1)
	covered := make([]bool, len(points)-1)
	for _, edge := range attributes.Edges {
		if edge.Begin < 0 || edge.End < edge.Begin || edge.End >= len(points) || edge.Density == nil || *edge.Density < 0 || *edge.Density > 15 || edge.Surface == "" || edge.Class == "" || edge.Use == "" {
			return routeMetrics{}, bad
		}
		for i := edge.Begin; i < edge.End; i++ {
			covered[i], allowed[i] = true, eligibleRoad(edge)
			paved[i] = pavedSurface(edge.Surface)
		}
	}
	metrics := routeMetrics{}
	for i, eligible := range allowed {
		if !covered[i] {
			return routeMetrics{}, bad
		}
		if eligible {
			metrics.eligibleMeters += cumulative[i+1] - cumulative[i]
		}
		if !paved[i] {
			metrics.unpavedMeters += cumulative[i+1] - cumulative[i]
		}
	}
	metrics.countryside = math.Min(1, metrics.eligibleMeters/total)
	blocked := []distanceInterval{}
	for _, leg := range route.Legs {
		for _, maneuver := range leg.Maneuvers {
			if maneuver.Begin < 0 || maneuver.End < maneuver.Begin || maneuver.End >= len(points) {
				return routeMetrics{}, bad
			}
			switch maneuver.Type {
			case "roundabout_enter", "roundabout_exit":
				blocked = append(blocked, distanceInterval{cumulative[maneuver.Begin] - 50, cumulative[maneuver.End] + 50})
			case "turn", "merge", "fork", "on_ramp", "off_ramp":
				blocked = append(blocked, distanceInterval{cumulative[maneuver.Begin] - 60, cumulative[maneuver.Begin] + 60})
			}
		}
	}
	// Uniform 20 m sampling prevents dense shape vertices being mistaken for additional bends.
	step := 20.0
	samples := []Point{}
	segments := []int{}
	segment := 0
	for at := 0.0; at <= total; at += step {
		for segment < len(points)-2 && cumulative[segment+1] < at {
			segment++
		}
		span := cumulative[segment+1] - cumulative[segment]
		t := 0.0
		if span > 0 {
			t = (at - cumulative[segment]) / span
		}
		longitude := points[segment+1].Longitude - points[segment].Longitude
		if longitude > 180 {
			longitude -= 360
		}
		if longitude < -180 {
			longitude += 360
		}
		samples = append(samples, Point{points[segment].Latitude + (points[segment+1].Latitude-points[segment].Latitude)*t, points[segment].Longitude + longitude*t})
		segments = append(segments, segment)
	}
	for i := 1; i+1 < len(samples); i++ {
		begin, end := max(0, i-4), min(len(samples)-2, i+3)
		if math.Abs(bearingDelta(bearing(samples[begin], samples[begin+1]), bearing(samples[end], samples[end+1]))) > 130 {
			blocked = append(blocked, distanceInterval{float64(i)*step - 100, float64(i)*step + 100})
		}
	}
	active, sign := false, 0.0
	blockedSamples := make([]bool, len(samples))
	for _, interval := range blocked {
		begin := max(0, int(math.Ceil(interval.begin/step)))
		end := min(len(samples)-1, int(math.Floor(interval.end/step)))
		for i := begin; i <= end; i++ {
			blockedSamples[i] = true
		}
	}
	lastBend := -1000.0
	peak, peakAt := 0.0, 0.0
	finish := func() {
		if active && peakAt-lastBend >= 80 {
			metrics.bends++
			lastBend = peakAt
		}
		active, peak = false, 0
	}
	for i := 2; i+2 < len(samples); i++ {
		eligible := allowed[segments[i-2]] && allowed[segments[i]] && allowed[segments[i+2]]
		eligible = eligible && !blockedSamples[i]
		angle := bearingDelta(bearing(samples[i-2], samples[i]), bearing(samples[i], samples[i+2]))
		magnitude := math.Abs(angle)
		if !eligible || magnitude < 12 || magnitude > 105 {
			finish()
			continue
		}
		if active && math.Signbit(angle) != math.Signbit(sign) {
			finish()
		}
		active, sign = true, angle
		if magnitude > peak {
			peak, peakAt = magnitude, float64(i)*step
		}
	}
	finish()
	metrics.density = float64(metrics.bends) / (total / 1000)
	return metrics, nil
}

func bearing(a, b Point) float64 {
	r := math.Pi / 180
	lat1, lat2, longitude := a.Latitude*r, b.Latitude*r, (b.Longitude-a.Longitude)*r
	return math.Atan2(math.Sin(longitude)*math.Cos(lat2), math.Cos(lat1)*math.Sin(lat2)-math.Sin(lat1)*math.Cos(lat2)*math.Cos(longitude)) * 180 / math.Pi
}
func bearingDelta(a, b float64) float64 {
	d := math.Mod(b-a+540, 360) - 180
	return d
}
