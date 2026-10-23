package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/url"
	"strings"
	"time"
)

type Point struct {
	Latitude  float64 `json:"latitude"`
	Longitude float64 `json:"longitude"`
}

func (p *Point) UnmarshalJSON(data []byte) error {
	var wire struct {
		Latitude  *float64 `json:"latitude"`
		Longitude *float64 `json:"longitude"`
	}
	d := json.NewDecoder(bytes.NewReader(data))
	d.DisallowUnknownFields()
	if err := d.Decode(&wire); err != nil {
		return err
	}
	if wire.Latitude == nil || wire.Longitude == nil {
		return apiError("invalid_request")
	}
	p.Latitude = *wire.Latitude
	p.Longitude = *wire.Longitude
	return nil
}

func (p Point) valid() bool {
	return finite(p.Latitude) && finite(p.Longitude) && math.Abs(p.Latitude) <= 90 && math.Abs(p.Longitude) <= 180
}
func finite(x float64) bool { return !math.IsNaN(x) && !math.IsInf(x, 0) }
func distance(a, b Point) float64 {
	r := math.Pi / 180
	dlat := (b.Latitude - a.Latitude) * r
	dlon := (b.Longitude - a.Longitude) * r
	x := math.Pow(math.Sin(dlat/2), 2) + math.Cos(a.Latitude*r)*math.Cos(b.Latitude*r)*math.Pow(math.Sin(dlon/2), 2)
	return 6371000 * 2 * math.Asin(math.Sqrt(math.Min(1, x)))
}

type WaypointRequest struct {
	Coordinate Point    `json:"coordinate"`
	Kind       string   `json:"kind"`
	Heading    *float64 `json:"headingDegrees,omitempty"`
	Tolerance  *float64 `json:"headingToleranceDegrees,omitempty"`
}
type Preferences struct {
	Tolls     string `json:"tolls"`
	Motorways string `json:"motorways"`
	Ferries   string `json:"ferries"`
}
type RouteRequest struct {
	Waypoints    []WaypointRequest `json:"waypoints"`
	Profile      string            `json:"profile"`
	Objective    string            `json:"objective"`
	Preferences  Preferences       `json:"preferences"`
	Alternatives int               `json:"alternatives"`
	Language     string            `json:"language"`
}

func (r *RouteRequest) UnmarshalJSON(data []byte) error {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		return err
	}
	for _, k := range []string{"waypoints", "profile", "objective", "preferences", "alternatives", "language"} {
		if len(fields[k]) == 0 || string(fields[k]) == "null" {
			return apiError("invalid_request")
		}
	}
	type plain RouteRequest
	var decoded plain
	d := json.NewDecoder(bytes.NewReader(data))
	d.DisallowUnknownFields()
	if err := d.Decode(&decoded); err != nil {
		return err
	}
	var waypoints []map[string]json.RawMessage
	if err := json.Unmarshal(fields["waypoints"], &waypoints); err != nil {
		return err
	}
	for _, w := range waypoints {
		if len(w["coordinate"]) == 0 || string(w["coordinate"]) == "null" {
			return apiError("invalid_request")
		}
	}
	*r = RouteRequest(decoded)
	return nil
}

type APIError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (e *APIError) Error() string    { return e.Code }
func apiError(code string) *APIError { return &APIError{code, strings.ReplaceAll(code, "_", " ")} }
func (r RouteRequest) validate() error {
	if r.Profile != "car" || r.Objective != "fastest" {
		return apiError("unsupported_option")
	}
	if len(r.Waypoints) < 2 || len(r.Waypoints) > 10 || r.Alternatives < 0 || r.Alternatives > 2 {
		return apiError("invalid_request")
	}
	for _, p := range r.Waypoints {
		if !p.Coordinate.valid() || p.Kind != "stop" {
			return apiError("invalid_request")
		}
		if p.Heading != nil && (!finite(*p.Heading) || *p.Heading < 0 || *p.Heading >= 360) {
			return apiError("invalid_request")
		}
		if p.Tolerance != nil && (p.Heading == nil || !finite(*p.Tolerance) || *p.Tolerance < 0 || *p.Tolerance > 180) {
			return apiError("invalid_request")
		}
	}
	for _, s := range []string{r.Preferences.Tolls, r.Preferences.Motorways, r.Preferences.Ferries} {
		if s != "neutral" && s != "avoid" {
			return apiError("unsupported_option")
		}
	}
	if len(r.Language) < 2 || len(r.Language) > 35 {
		return apiError("invalid_request")
	}
	for _, c := range r.Language {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-') {
			return apiError("invalid_request")
		}
	}
	return nil
}

type Summary struct {
	Distance float64 `json:"distanceMeters"`
	Duration float64 `json:"durationSeconds"`
}
type Geometry struct {
	Encoding   string `json:"encoding"`
	Dimensions int    `json:"dimensions"`
	Count      int    `json:"pointCount"`
	Data       string `json:"data"`
}
type Waypoint struct {
	Requested    Point   `json:"requested"`
	Snapped      Point   `json:"snapped"`
	SnapDistance float64 `json:"snapDistanceMeters"`
	Index        int     `json:"geometryIndex"`
}
type Spoken struct {
	Alert    string `json:"alert,omitempty"`
	Before   string `json:"before,omitempty"`
	After    string `json:"after,omitempty"`
	MultiCue bool   `json:"multiCue"`
}
type Sign struct {
	Kind string `json:"kind"`
	Text string `json:"text"`
}
type Maneuver struct {
	ID             string   `json:"id"`
	Type           string   `json:"type"`
	Modifier       string   `json:"modifier"`
	Begin          int      `json:"beginIndex"`
	End            int      `json:"endIndex"`
	Distance       float64  `json:"distanceMeters"`
	Duration       float64  `json:"durationSeconds"`
	Instruction    string   `json:"instruction"`
	Spoken         Spoken   `json:"spoken"`
	StreetNames    []string `json:"streetNames,omitempty"`
	Signs          []Sign   `json:"signs,omitempty"`
	RoundaboutExit *int     `json:"roundaboutExit,omitempty"`
}
type Leg struct {
	Begin     int        `json:"beginIndex"`
	End       int        `json:"endIndex"`
	Summary   Summary    `json:"summary"`
	Maneuvers []Maneuver `json:"maneuvers"`
}
type Anchor struct {
	Index   int     `json:"geometryIndex"`
	Elapsed float64 `json:"elapsedSeconds"`
}
type Timing struct {
	Method  string   `json:"method"`
	Traffic string   `json:"traffic"`
	Anchors []Anchor `json:"anchors"`
}
type Route struct {
	ID          string      `json:"id"`
	Summary     Summary     `json:"summary"`
	Geometry    Geometry    `json:"geometry"`
	Waypoints   []Waypoint  `json:"waypoints"`
	Legs        []Leg       `json:"legs"`
	Timing      Timing      `json:"timing"`
	Language    string      `json:"language"`
	Preferences Preferences `json:"appliedPreferences"`
}
type Warning struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}
type Provenance struct {
	Engine       string `json:"engine"`
	Adapter      string `json:"adapterVersion"`
	GraphVersion string `json:"graphVersion,omitempty"`
}
type RouteResponse struct {
	RequestID    string     `json:"requestId"`
	GeneratedAt  time.Time  `json:"generatedAt"`
	Routes       []Route    `json:"routes"`
	Warnings     []Warning  `json:"warnings"`
	Attributions []string   `json:"attributions"`
	Provenance   Provenance `json:"provenance"`
}

func identifier() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b[:])
}

type RoutingProvider interface {
	Routes(context.Context, RouteRequest) ([]Route, []Warning, error)
	Ready(context.Context) error
}
type Valhalla struct {
	BaseURL string
	Client  *http.Client
}

func newValhalla(base string) (*Valhalla, error) {
	u, err := url.Parse(base)
	if err != nil || u.Host == "" || (u.Scheme != "http" && u.Scheme != "https") || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return nil, fmt.Errorf("invalid VALHALLA_BASE_URL")
	}
	return &Valhalla{strings.TrimRight(base, "/"), &http.Client{Timeout: 15 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}, nil
}
func (v *Valhalla) Ready(ctx context.Context) error {
	req, _ := http.NewRequestWithContext(ctx, "GET", v.BaseURL+"/status", nil)
	res, err := v.Client.Do(req)
	if err != nil {
		return apiError("upstream_unavailable")
	}
	defer res.Body.Close()
	if res.StatusCode != 200 {
		return apiError("upstream_unavailable")
	}
	return nil
}

type vhSummary struct {
	Length float64 `json:"length"`
	Time   float64 `json:"time"`
}
type vhManeuver struct {
	Type        int      `json:"type"`
	Begin       int      `json:"begin_shape_index"`
	End         int      `json:"end_shape_index"`
	Length      float64  `json:"length"`
	Time        float64  `json:"time"`
	Instruction string   `json:"instruction"`
	Alert       string   `json:"verbal_transition_alert_instruction"`
	Before      string   `json:"verbal_pre_transition_instruction"`
	After       string   `json:"verbal_post_transition_instruction"`
	MultiCue    bool     `json:"verbal_multi_cue"`
	Streets     []string `json:"street_names"`
	Exit        *int     `json:"roundabout_exit_count"`
	Signs       map[string][]struct {
		Text string `json:"text"`
	} `json:"sign"`
}
type vhLeg struct {
	Shape     string       `json:"shape"`
	Summary   vhSummary    `json:"summary"`
	Maneuvers []vhManeuver `json:"maneuvers"`
}
type vhTrip struct {
	Status   int       `json:"status"`
	Units    string    `json:"units"`
	Language string    `json:"language"`
	Summary  vhSummary `json:"summary"`
	Legs     []vhLeg   `json:"legs"`
}
type vhResponse struct {
	Trip       vhTrip `json:"trip"`
	Alternates []struct {
		Trip vhTrip `json:"trip"`
	} `json:"alternates"`
}

func (v *Valhalla) Routes(ctx context.Context, r RouteRequest) ([]Route, []Warning, error) {
	locations := make([]map[string]any, len(r.Waypoints))
	for i, w := range r.Waypoints {
		p := map[string]any{"lat": w.Coordinate.Latitude, "lon": w.Coordinate.Longitude, "type": "break"}
		if w.Heading != nil {
			p["heading"] = *w.Heading
		}
		if w.Tolerance != nil {
			p["heading_tolerance"] = *w.Tolerance
		}
		locations[i] = p
	}
	preference := func(s string) float64 {
		if s == "avoid" {
			return 0
		}
		return .5
	}
	payload := map[string]any{"locations": locations, "costing": "auto", "alternates": r.Alternatives, "units": "kilometers", "language": r.Language, "directions_type": "instructions", "costing_options": map[string]any{"auto": map[string]any{"use_tolls": preference(r.Preferences.Tolls), "use_highways": preference(r.Preferences.Motorways), "use_ferry": preference(r.Preferences.Ferries)}}}
	data, _ := json.Marshal(payload)
	req, _ := http.NewRequestWithContext(ctx, "POST", v.BaseURL+"/route", strings.NewReader(string(data)))
	req.Header.Set("Content-Type", "application/json")
	res, err := v.Client.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return nil, nil, ctx.Err()
		}
		var e interface{ Timeout() bool }
		if errors.As(err, &e) && e.Timeout() {
			return nil, nil, apiError("upstream_timeout")
		}
		return nil, nil, apiError("upstream_unavailable")
	}
	defer res.Body.Close()
	body, err := io.ReadAll(io.LimitReader(res.Body, 8_000_001))
	if err != nil {
		if ctx.Err() != nil {
			return nil, nil, ctx.Err()
		}
		var timeout interface{ Timeout() bool }
		if errors.As(err, &timeout) && timeout.Timeout() {
			return nil, nil, apiError("upstream_timeout")
		}
		return nil, nil, apiError("invalid_upstream_response")
	}
	if len(body) > 8_000_000 {
		return nil, nil, apiError("invalid_upstream_response")
	}
	if res.StatusCode != 200 {
		var e struct {
			Code int `json:"error_code"`
		}
		_ = json.Unmarshal(body, &e)
		switch e.Code {
		case 171:
			return nil, nil, apiError("cannot_snap")
		case 170, 442:
			return nil, nil, apiError("no_route")
		case 150, 151, 152, 153, 154:
			return nil, nil, apiError("limit_exceeded")
		}
		return nil, nil, apiError("upstream_unavailable")
	}
	var response vhResponse
	if json.Unmarshal(body, &response) != nil {
		return nil, nil, apiError("invalid_upstream_response")
	}
	primary, err := normalize(response.Trip, r)
	if err != nil {
		return nil, nil, err
	}
	routes := []Route{primary}
	warnings := []Warning{}
	for i, alt := range response.Alternates {
		if i >= r.Alternatives {
			break
		}
		route, err := normalize(alt.Trip, r)
		if err != nil {
			warnings = append(warnings, Warning{"alternative_discarded", "An unusable alternative was omitted."})
			continue
		}
		routes = append(routes, route)
	}
	return routes, warnings, nil
}
func normalize(t vhTrip, req RouteRequest) (Route, error) {
	bad := apiError("invalid_upstream_response")
	factor := 1000.0
	if t.Units == "miles" {
		factor = 1609.344
	} else if t.Units != "kilometers" {
		return Route{}, bad
	}
	if t.Status != 0 || len(t.Legs) != len(req.Waypoints)-1 || !finite(t.Summary.Length) || t.Summary.Length <= 0 || !finite(t.Summary.Time) || t.Summary.Time < 0 || t.Language == "" {
		return Route{}, bad
	}
	r := Route{ID: identifier(), Summary: Summary{t.Summary.Length * factor, t.Summary.Time}, Language: t.Language, Preferences: req.Preferences, Timing: Timing{Method: "maneuver_interpolation", Traffic: "unknown", Anchors: []Anchor{{0, 0}}}}
	if !finite(r.Summary.Distance) {
		return Route{}, bad
	}
	var points []Point
	var elapsed float64
	var totalLegTime, totalLegDistance float64
	for li, leg := range t.Legs {
		p, err := decodePolyline(leg.Shape)
		if err != nil {
			return Route{}, bad
		}
		offset := len(points)
		if offset > 0 {
			offset--
			if distance(points[offset], p[0]) > 2 {
				return Route{}, bad
			}
			points = append(points, p[1:]...)
		} else {
			points = append(points, p...)
		}
		if len(points) > 100000 || len(leg.Maneuvers) == 0 || !finite(leg.Summary.Time) || leg.Summary.Time < 0 || !finite(leg.Summary.Length) || leg.Summary.Length < 0 {
			return Route{}, bad
		}
		l := Leg{Begin: offset, End: len(points) - 1, Summary: Summary{leg.Summary.Length * factor, leg.Summary.Time}, Maneuvers: []Maneuver{}}
		if !finite(l.Summary.Distance) {
			return Route{}, bad
		}
		previous := 0
		var sumTime float64
		for mi, m := range leg.Maneuvers {
			if m.Begin < previous || m.End < m.Begin || m.End >= len(p) || m.Instruction == "" || !finite(m.Time) || m.Time < 0 || !finite(m.Length) || m.Length < 0 {
				return Route{}, bad
			}
			previous = m.Begin
			sumTime += m.Time
			kind, modifier := maneuverType(m.Type)
			n := Maneuver{ID: fmt.Sprintf("%d-%d", li, mi), Type: kind, Modifier: modifier, Begin: offset + m.Begin, End: offset + m.End, Distance: m.Length * factor, Duration: m.Time, Instruction: m.Instruction, Spoken: Spoken{m.Alert, m.Before, m.After, m.MultiCue}, StreetNames: m.Streets, RoundaboutExit: m.Exit}
			if !finite(n.Distance) || !finite(sumTime) {
				return Route{}, bad
			}
			if n.RoundaboutExit != nil && *n.RoundaboutExit <= 0 {
				n.RoundaboutExit = nil
			}
			for _, key := range []string{"exit_number_elements", "exit_branch_elements", "exit_toward_elements", "exit_name_elements"} {
				for _, s := range m.Signs[key] {
					n.Signs = append(n.Signs, Sign{strings.TrimSuffix(key, "_elements"), s.Text})
				}
			}
			l.Maneuvers = append(l.Maneuvers, n)
		}
		if l.Maneuvers[0].Begin != l.Begin || l.Maneuvers[len(l.Maneuvers)-1].End != l.End {
			return Route{}, bad
		}
		// Scale maneuver estimates to the authoritative leg total; no claim of per-edge timing.
		for _, m := range l.Maneuvers {
			r.Timing.Anchors = append(r.Timing.Anchors, Anchor{m.Begin, elapsed})
			if sumTime > 0 {
				elapsed += (m.Duration / sumTime) * leg.Summary.Time
			}
			r.Timing.Anchors = append(r.Timing.Anchors, Anchor{m.End, elapsed})
		}
		if sumTime == 0 {
			elapsed += leg.Summary.Time
			r.Timing.Anchors = append(r.Timing.Anchors, Anchor{l.End, elapsed})
		}
		r.Legs = append(r.Legs, l)
		totalLegTime += leg.Summary.Time
		totalLegDistance += l.Summary.Distance
		if li == 0 {
			r.Waypoints = append(r.Waypoints, Waypoint{req.Waypoints[0].Coordinate, points[0], distance(req.Waypoints[0].Coordinate, points[0]), 0})
		}
		r.Waypoints = append(r.Waypoints, Waypoint{req.Waypoints[li+1].Coordinate, points[l.End], distance(req.Waypoints[li+1].Coordinate, points[l.End]), l.End})
	}
	if math.Abs(totalLegTime-r.Summary.Duration) > math.Max(2, r.Summary.Duration*.02) || math.Abs(totalLegDistance-r.Summary.Distance) > math.Max(10, r.Summary.Distance*.02) {
		return Route{}, bad
	}
	if elapsed > 0 {
		for i := range r.Timing.Anchors {
			r.Timing.Anchors[i].Elapsed *= r.Summary.Duration / elapsed
		}
	}
	last := -1
	for _, a := range r.Timing.Anchors {
		if a.Index < last {
			return Route{}, bad
		}
		last = a.Index
	}
	if distanceAlong(points) <= 0 {
		return Route{}, bad
	}
	r.Geometry = Geometry{"polyline6", 2, len(points), encodePolyline(points)}
	return r, nil
}
func maneuverType(t int) (string, string) {
	switch t {
	case 1, 2, 3:
		return "depart", "none"
	case 4, 5, 6:
		return "arrive", "none"
	case 7, 8:
		return "continue", "straight"
	case 9:
		return "turn", "slight_right"
	case 10:
		return "turn", "right"
	case 11:
		return "turn", "sharp_right"
	case 12, 13:
		return "turn", "uturn"
	case 14:
		return "turn", "sharp_left"
	case 15:
		return "turn", "left"
	case 16:
		return "turn", "slight_left"
	case 17:
		return "on_ramp", "straight"
	case 18:
		return "on_ramp", "right"
	case 19:
		return "on_ramp", "left"
	case 20:
		return "off_ramp", "right"
	case 21:
		return "off_ramp", "left"
	case 22:
		return "fork", "straight"
	case 23:
		return "fork", "right"
	case 24:
		return "fork", "left"
	case 25:
		return "merge", "none"
	case 26:
		return "roundabout_enter", "none"
	case 27:
		return "roundabout_exit", "none"
	case 28, 29:
		return "notification", "none"
	case 37:
		return "merge", "right"
	case 38:
		return "merge", "left"
	}
	return "unknown", "none"
}
func distanceAlong(p []Point) float64 {
	var d float64
	for i := 1; i < len(p); i++ {
		d += distance(p[i-1], p[i])
	}
	return d
}
func decodePolyline(s string) ([]Point, error) {
	if len(s) > 2000000 {
		return nil, apiError("invalid_upstream_response")
	}
	i := 0
	read := func() (int64, error) {
		var n int64
		for shift := uint(0); shift <= 30 && i < len(s); shift += 5 {
			b := s[i]
			i++
			if b < 63 || b > 126 {
				return 0, apiError("invalid_upstream_response")
			}
			v := int64(b - 63)
			n |= (v & 31) << shift
			if v < 32 {
				if n&1 != 0 {
					return ^(n >> 1), nil
				}
				return n >> 1, nil
			}
		}
		return 0, apiError("invalid_upstream_response")
	}
	var lat, lon int64
	var p []Point
	for i < len(s) {
		a, e := read()
		if e != nil {
			return nil, e
		}
		b, e := read()
		if e != nil {
			return nil, e
		}
		lat += a
		lon += b
		x := Point{float64(lat) / 1e6, float64(lon) / 1e6}
		if !x.valid() || len(p) >= 100000 {
			return nil, apiError("invalid_upstream_response")
		}
		p = append(p, x)
	}
	if len(p) < 2 {
		return nil, apiError("invalid_upstream_response")
	}
	return p, nil
}
func encodePolyline(p []Point) string {
	var b strings.Builder
	var last [2]int64
	for _, x := range p {
		for j, v := range []float64{x.Latitude, x.Longitude} {
			n := int64(math.Round(v * 1e6))
			d := n - last[j]
			last[j] = n
			u := uint64(d << 1)
			if d < 0 {
				u = uint64(^(d << 1))
			}
			for u >= 32 {
				b.WriteByte(byte(u&31|32) + 63)
				u >>= 5
			}
			b.WriteByte(byte(u) + 63)
		}
	}
	return b.String()
}
