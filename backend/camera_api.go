package main

import (
	"context"
	"encoding/json"
	"io"
	"math"
	"mime"
	"net/http"
	"time"
)

type CameraBBox struct {
	South *float64 `json:"south"`
	West  *float64 `json:"west"`
	North *float64 `json:"north"`
	East  *float64 `json:"east"`
}
type CameraRouteQuery struct {
	Encoding       string  `json:"encoding"`
	Data           string  `json:"data"`
	CorridorMeters float64 `json:"corridorMeters"`
}
type CameraRequest struct {
	BBox  *CameraBBox       `json:"bbox"`
	Route *CameraRouteQuery `json:"route,omitempty"`
}
type CameraResponse struct {
	Dataset   CameraDataset      `json:"dataset"`
	Cameras   []Camera           `json:"cameras"`
	Zones     []AverageSpeedZone `json:"averageSpeedZones"`
	Truncated bool               `json:"truncated"`
	Warnings  []Warning          `json:"warnings"`
}
type cameraService struct {
	store      *CameraStore
	attributes roadAttributeProvider
	slots      chan struct{}
	limit      int
}

func newCameraService(store *CameraStore, attributes roadAttributeProvider) *cameraService {
	return &cameraService{store, attributes, make(chan struct{}, 4), 5000}
}
func (q CameraRequest) validate() ([]Point, error) {
	b := q.BBox
	if b == nil || b.South == nil || b.North == nil || b.West == nil || b.East == nil {
		return nil, apiError("invalid_request")
	}
	if !(Point{Latitude: *b.South, Longitude: *b.West}).valid() {
		return nil, apiError("invalid_request")
	}
	if !(Point{Latitude: *b.North, Longitude: *b.East}).valid() {
		return nil, apiError("invalid_request")
	}
	if *b.South > *b.North || *b.West > *b.East {
		return nil, apiError("invalid_request")
	}
	if q.Route == nil {
		return nil, nil
	}
	if q.Route.Encoding != "polyline6" || !finite(q.Route.CorridorMeters) || q.Route.CorridorMeters <= 0 || q.Route.CorridorMeters > 5000 {
		return nil, apiError("invalid_request")
	}
	p, err := decodePolyline(q.Route.Data)
	if err != nil {
		return nil, apiError("invalid_request")
	}
	if len(p) > 10000 {
		return nil, apiError("limit_exceeded")
	}
	length := 0.0
	for i := 1; i < len(p); i++ {
		length += distance(p[i-1], p[i])
	}
	if length > 1_000_000 {
		return nil, apiError("limit_exceeded")
	}
	return p, nil
}
func (s *cameraService) serveHTTP(w http.ResponseWriter, r *http.Request) {
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
	r.Body = http.MaxBytesReader(w, r.Body, 256_000)
	defer r.Body.Close()
	d := json.NewDecoder(r.Body)
	d.DisallowUnknownFields()
	var q CameraRequest
	if err = d.Decode(&q); err != nil {
		if _, ok := err.(*http.MaxBytesError); ok {
			fail(413, "limit_exceeded")
		} else {
			fail(400, "invalid_request")
		}
		return
	}
	if d.Decode(new(any)) != io.EOF {
		fail(400, "invalid_request")
		return
	}
	points, err := q.validate()
	if err != nil {
		code := err.(*APIError).Code
		status := 400
		if code == "limit_exceeded" {
			status = 413
		}
		fail(status, code)
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
	ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
	defer cancel()
	response := s.query(ctx, q, points)
	_ = json.NewEncoder(w).Encode(response)
}

type routeProjection struct {
	along, lateral float64
	segment        int
	fraction       float64
}

func projectCamera(p, a, b Point) (float64, float64) {
	r := math.Pi / 180
	scale := 6371000.0
	delta := func(x float64) float64 { return math.Mod(x+540, 360) - 180 }
	x := delta(b.Longitude-a.Longitude) * r * math.Cos(a.Latitude*r) * scale
	y := (b.Latitude - a.Latitude) * r * scale
	px := delta(p.Longitude-a.Longitude) * r * math.Cos(a.Latitude*r) * scale
	py := (p.Latitude - a.Latitude) * r * scale
	t := 0.0
	if length := x*x + y*y; length > 0 {
		t = math.Max(0, math.Min(1, (px*x+py*y)/length))
	}
	return t, math.Hypot(px-t*x, py-t*y)
}
func cameraCumulative(points []Point) []float64 {
	out := make([]float64, len(points))
	for i := 1; i < len(points); i++ {
		out[i] = out[i-1] + distance(points[i-1], points[i])
	}
	return out
}
func projectOnRoute(p Point, route []Point, cumulative []float64) routeProjection {
	best := routeProjection{lateral: math.Inf(1), segment: -1}
	for i := 1; i < len(route); i++ {
		f, d := projectCamera(p, route[i-1], route[i])
		if d < best.lateral {
			best = routeProjection{cumulative[i-1] + f*(cumulative[i]-cumulative[i-1]), d, i - 1, f}
		}
	}
	return best
}
func (b CameraBBox) contains(p Point) bool {
	return p.Latitude >= *b.South && p.Latitude <= *b.North && p.Longitude >= *b.West && p.Longitude <= *b.East
}

// Liang-Barsky rectangle clipping includes crossing zones with both ends outside.
func (b CameraBBox) intersects(line []Point) bool {
	for _, p := range line {
		if b.contains(p) {
			return true
		}
	}
	for i := 1; i < len(line); i++ {
		a, c := line[i-1], line[i]
		dx, dy := c.Longitude-a.Longitude, c.Latitude-a.Latitude
		t0, t1 := 0.0, 1.0
		ps := []float64{-dx, dx, -dy, dy}
		qs := []float64{a.Longitude - *b.West, *b.East - a.Longitude, a.Latitude - *b.South, *b.North - a.Latitude}
		ok := true
		for j, p := range ps {
			if p == 0 {
				if qs[j] < 0 {
					ok = false
					break
				}
				continue
			}
			v := qs[j] / p
			if p < 0 {
				t0 = math.Max(t0, v)
			} else {
				t1 = math.Min(t1, v)
			}
			if t0 > t1 {
				ok = false
				break
			}
		}
		if ok {
			return true
		}
	}
	return false
}
func segmentCross(a, b, c, d Point) bool {
	cross := func(p, q, r Point) float64 {
		return (q.Longitude-p.Longitude)*(r.Latitude-p.Latitude) - (q.Latitude-p.Latitude)*(r.Longitude-p.Longitude)
	}
	// Collinear segments are handled by point-to-segment projection instead.
	x, y, z, v := cross(a, b, c), cross(a, b, d), cross(c, d, a), cross(c, d, b)
	return ((x < 0 && y > 0) || (x > 0 && y < 0)) && ((z < 0 && v > 0) || (z > 0 && v < 0))
}
func geometryNearRoute(ctx context.Context, geometry, route []Point, cumulative []float64, corridor float64) bool {
	for _, p := range geometry {
		if ctx.Err() != nil {
			return false
		}
		if projectOnRoute(p, route, cumulative).lateral <= corridor {
			return true
		}
	}
	for i := 1; i < len(geometry); i++ {
		if ctx.Err() != nil {
			return false
		}
		for j := 1; j < len(route); j++ {
			if segmentCross(geometry[i-1], geometry[i], route[j-1], route[j]) {
				return true
			}
			_, a := projectCamera(route[j-1], geometry[i-1], geometry[i])
			_, b := projectCamera(route[j], geometry[i-1], geometry[i])
			if a <= corridor || b <= corridor {
				return true
			}
		}
	}
	return false
}
func edgeEvidence(p routeProjection, ways []int64, attributes roadAttributes) bool {
	for _, e := range attributes.Edges {
		if e.WayID <= 0 || p.segment < e.Begin || p.segment >= e.End {
			continue
		}
		for _, id := range ways {
			if id == e.WayID {
				return true
			}
		}
	}
	return false
}
func compatibleDirection(d *float64, p routeProjection, route []Point) bool {
	if d == nil {
		return true
	}
	if p.segment < 0 {
		return false
	}
	diff := math.Abs(*d - cameraTravelBearing(route[p.segment], route[p.segment+1]))
	return math.Min(diff, 360-diff) <= 60
}

func compatibleCameraOrientation(c Camera, p routeProjection, route []Point) bool {
	if !projectionSupportsConfirmation(c.Coordinate, p, route) {
		return false
	}
	if c.DirectionDegrees != nil {
		return compatibleDirection(c.DirectionDegrees, p, route)
	}
	// Without enforced travel direction, require local road-axis alignment. A way
	// ID on its own does not resolve a perpendicular crossing or endpoint snap.
	if len(c.RoadGeometry) < 2 || p.segment < 0 {
		return false
	}
	road := projectOnRoute(c.Coordinate, c.RoadGeometry, cameraCumulative(c.RoadGeometry))
	if road.lateral > 100 {
		return false
	}
	d := math.Abs(bearingDelta(cameraTravelBearing(c.RoadGeometry[road.segment], c.RoadGeometry[road.segment+1]), cameraTravelBearing(route[p.segment], route[p.segment+1])))
	return math.Min(d, 180-d) <= 30
}

func projectionSupportsConfirmation(coordinate Point, p routeProjection, route []Point) bool {
	if p.segment < 0 || distance(route[p.segment], route[p.segment+1]) < 0.05 {
		return false
	}
	travel := cameraTravelBearing(route[p.segment], route[p.segment+1])
	if p.segment == 0 && p.fraction == 0 && distance(coordinate, route[0]) > 1 {
		if math.Abs(bearingDelta(travel, cameraTravelBearing(route[0], coordinate))) > 90 {
			return false
		}
	}
	last := len(route) - 1
	if p.segment == last-1 && p.fraction == 1 && distance(coordinate, route[last]) > 1 {
		if math.Abs(bearingDelta(travel, cameraTravelBearing(route[last], coordinate))) < 90 {
			return false
		}
	}
	return true
}
func (s *cameraService) query(ctx context.Context, q CameraRequest, route []Point) CameraResponse {
	snapshot := s.store.read()
	out := CameraResponse{Dataset: snapshot.Dataset, Cameras: []Camera{}, Zones: []AverageSpeedZone{}, Warnings: []Warning{}}
	if snapshot.Dataset.Version == "" {
		out.Warnings = append(out.Warnings, Warning{"camera_dataset_missing", "NL camera data is not available yet."})
		return out
	}
	if out.Dataset.Stale {
		out.Warnings = append(out.Warnings, Warning{"camera_dataset_stale", "Source snapshot or successful check time is missing, older than 24 hours, or implausibly in the future."})
	}
	if out.Dataset.IncompleteZoneCount > 0 {
		out.Warnings = append(out.Warnings, Warning{"incomplete_zone_geometry", "Some mapped average-speed zones have unresolved road geometry."})
	}
	var attributes roadAttributes
	cumulative := cameraCumulative(route)
	if len(route) > 0 {
		var err error
		if s.attributes != nil {
			traceCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
			attributes, err = s.attributes.attributesFor(traceCtx, Route{Geometry: Geometry{Encoding: "polyline6", Data: q.Route.Data}})
			cancel()
		}
		if err != nil {
			attributes = roadAttributes{}
		}
		validEdges := []roadEdge{}
		for _, edge := range attributes.Edges {
			if edge.Begin >= 0 && edge.End > edge.Begin && edge.End < len(route) && edge.WayID > 0 {
				validEdges = append(validEdges, edge)
			}
		}
		attributes.Edges = validEdges
		hasWayIDs := false
		for _, edge := range attributes.Edges {
			if edge.WayID > 0 {
				hasWayIDs = true
			}
		}
		if s.attributes == nil || err != nil || !hasWayIDs {
			out.Warnings = append(out.Warnings, Warning{"route_identity_unavailable", "Road identity is unavailable; geometric proximity alone is not confirmed relevance."})
		}
	}
	appendCamera := func(c Camera) {
		if len(out.Cameras)+len(out.Zones) >= s.limit {
			out.Truncated = true
			return
		}
		out.Cameras = append(out.Cameras, c)
	}
	appendZone := func(z AverageSpeedZone) {
		if len(out.Cameras)+len(out.Zones) >= s.limit {
			out.Truncated = true
			return
		}
		out.Zones = append(out.Zones, z)
	}
	expired := func() bool {
		if ctx.Err() == nil {
			return false
		}
		out.Truncated = true
		out.Warnings = append(out.Warnings, Warning{"camera_query_timeout", "Query processing deadline exceeded; returned records are incomplete."})
		return true
	}
	for _, original := range snapshot.Cameras {
		if expired() {
			return out
		}
		c := original
		visible := q.BBox.contains(c.Coordinate)
		if len(route) > 0 {
			p := projectOnRoute(c.Coordinate, route, cumulative)
			c.RouteMatch = "none"
			if p.lateral <= q.Route.CorridorMeters {
				visible = true
				c.RouteDistanceMeters = &p.along
				c.RouteLateralMeters = &p.lateral
				c.RouteMatch = "nearby"
				if p.lateral <= 50 && edgeEvidence(p, c.RoadWayIDs, attributes) && compatibleCameraOrientation(c, p, route) {
					c.RouteMatch = "confirmed"
				}
			}
		}
		if visible {
			appendCamera(c)
		}
	}
	for _, original := range snapshot.Zones {
		if expired() {
			return out
		}
		z := original
		visible := q.BBox.intersects(z.Geometry) || (z.Start != nil && q.BBox.contains(*z.Start)) || (z.End != nil && q.BBox.contains(*z.End))
		if len(route) > 0 {
			z.RouteMatch = "none"
			near := geometryNearRoute(ctx, z.Geometry, route, cumulative, q.Route.CorridorMeters)
			if expired() {
				return out
			}
			if z.Start != nil && projectOnRoute(*z.Start, route, cumulative).lateral <= q.Route.CorridorMeters {
				near = true
			}
			if z.End != nil && projectOnRoute(*z.End, route, cumulative).lateral <= q.Route.CorridorMeters {
				near = true
			}
			if near {
				visible = true
				z.RouteMatch = "nearby"
				if z.GeometryVerified && len(z.Geometry) > 1 {
					start := projectOnRoute(z.Geometry[0], route, cumulative)
					end := projectOnRoute(z.Geometry[len(z.Geometry)-1], route, cumulative)
					z.RouteStartMeters = &start.along
					z.RouteEndMeters = &end.along
					confirmed := end.along > start.along
					previous := -1.0
					for _, p := range z.Geometry {
						if expired() {
							return out
						}
						projection := projectOnRoute(p, route, cumulative)
						if projection.lateral > 50 || projection.along+1 < previous || !edgeEvidence(projection, z.RoadWayIDs, attributes) {
							confirmed = false
							break
						}
						previous = projection.along
					}
					if confirmed {
						for i := 1; i < len(z.Geometry); i++ {
							if expired() {
								return out
							}
							a, b := z.Geometry[i-1], z.Geometry[i]
							mid := Point{(a.Latitude + b.Latitude) / 2, (a.Longitude + b.Longitude) / 2}
							projection := projectOnRoute(mid, route, cumulative)
							direction := cameraTravelBearing(a, b)
							if projection.lateral > 50 || !edgeEvidence(projection, z.RoadWayIDs, attributes) || !compatibleDirection(&direction, projection, route) || !projectionSupportsConfirmation(mid, projection, route) {
								confirmed = false
								break
							}
						}
					}
					if confirmed {
						z.RouteMatch = "confirmed"
					}
				}
			}
		}
		if visible {
			appendZone(z)
		}
	}
	if out.Truncated {
		out.Warnings = append(out.Warnings, Warning{"camera_results_truncated", "Query exceeds the 5000 record limit; use a smaller area or route."})
	}
	return out
}
