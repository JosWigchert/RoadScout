package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"sort"
	"strconv"
	"strings"
	"time"
)

type osmMember struct {
	Type string `json:"type"`
	Ref  int64  `json:"ref"`
	Role string `json:"role"`
}
type osmElement struct {
	Type    string            `json:"type"`
	ID      int64             `json:"id"`
	Lat     *float64          `json:"lat"`
	Lon     *float64          `json:"lon"`
	Nodes   []int64           `json:"nodes"`
	Members []osmMember       `json:"members"`
	Tags    map[string]string `json:"tags"`
}

func (e osmElement) key() string          { return fmt.Sprintf("osm:%s:%d", e.Type, e.ID) }
func osmKey(kind string, id int64) string { return fmt.Sprintf("osm:%s:%d", kind, id) }
func (e osmElement) point() *Point {
	if e.Lat == nil || e.Lon == nil {
		return nil
	}
	p := Point{*e.Lat, *e.Lon}
	if !p.valid() {
		return nil
	}
	return &p
}
func speedKph(tags map[string]string) *float64 {
	s := strings.TrimSpace(tags["maxspeed"])
	factor := 1.0
	if strings.HasSuffix(s, " mph") {
		s = strings.TrimSuffix(s, " mph")
		factor = 1.609344
	}
	s = strings.TrimSuffix(s, " km/h")
	x, err := strconv.ParseFloat(s, 64)
	if err != nil || !finite(x) || x <= 0 || x*factor > 400 {
		return nil
	}
	x *= factor
	return &x
}
func cameraTravelBearing(a, b Point) float64 {
	r := math.Pi / 180
	lat1, lat2 := a.Latitude*r, b.Latitude*r
	dl := (b.Longitude - a.Longitude) * r
	return math.Mod(math.Atan2(math.Sin(dl)*math.Cos(lat2), math.Cos(lat1)*math.Sin(lat2)-math.Sin(lat1)*math.Cos(lat2)*math.Cos(dl))*180/math.Pi+360, 360)
}
func sortedSources(in []string) []string {
	sort.Strings(in)
	out := []string{}
	for _, x := range in {
		if len(out) == 0 || out[len(out)-1] != x {
			out = append(out, x)
		}
	}
	return out
}

func importCameras(data []byte) (CameraSnapshot, error) {
	result := emptyCameraSnapshot()
	var doc struct {
		Remark string `json:"remark"`
		OSM3S  struct {
			Timestamp string `json:"timestamp_osm_base"`
		} `json:"osm3s"`
		Elements []osmElement `json:"elements"`
	}
	if json.Unmarshal(data, &doc) != nil || doc.Remark != "" {
		return result, errors.New("invalid or remark-bearing Overpass response")
	}
	stamp, err := time.Parse(time.RFC3339, doc.OSM3S.Timestamp)
	if err != nil {
		return result, errors.New("missing source snapshot time")
	}
	result.Dataset.SourceUpdatedAt = &stamp
	entities := map[string]osmElement{}
	counts := map[string]int{"node": 0, "way": 0, "relation": 0}
	var sentinel *osmElement
	for i, e := range doc.Elements {
		if e.Type == "count" {
			if sentinel != nil || i != len(doc.Elements)-1 {
				return result, errors.New("invalid count sentinel")
			}
			copy := e
			sentinel = &copy
			continue
		}
		if _, ok := counts[e.Type]; !ok || e.ID <= 0 {
			return result, errors.New("invalid OSM entity")
		}
		if _, exists := entities[e.key()]; exists {
			return result, errors.New("duplicate source entity")
		}
		entities[e.key()] = e
		counts[e.Type]++
	}
	if sentinel == nil || len(entities) == 0 {
		return result, errors.New("missing required query data/count sentinel")
	}
	for kind, n := range counts {
		value, err := strconv.Atoi(sentinel.Tags[kind+"s"])
		if err != nil || value != n {
			return result, errors.New("incomplete Overpass counts")
		}
	}
	total, err := strconv.Atoi(sentinel.Tags["total"])
	if err != nil || total != len(entities) {
		return result, errors.New("incomplete Overpass total")
	}
	for _, e := range entities {
		if e.Type == "node" && e.point() == nil {
			return result, errors.New("missing node coordinate")
		}
		for _, id := range e.Nodes {
			if _, ok := entities[osmKey("node", id)]; !ok {
				return result, errors.New("missing way node")
			}
		}
		for _, m := range e.Members {
			if _, ok := entities[osmKey(m.Type, m.Ref)]; !ok {
				return result, errors.New("missing relation member")
			}
		}
	}
	onWays := map[int64][]osmElement{}
	for _, e := range entities {
		if e.Type == "way" && e.Tags["highway"] != "" {
			for _, n := range e.Nodes {
				onWays[n] = append(onWays[n], e)
			}
		}
	}
	for n := range onWays {
		sort.Slice(onWays[n], func(i, j int) bool { return onWays[n][i].ID < onWays[n][j].ID })
	}
	cameras := map[string]Camera{}
	directionAmbiguous := map[string]bool{}
	geometryAmbiguous := map[string]bool{}
	makeCamera := func(node osmElement, kind string) Camera {
		c := Camera{ID: node.key(), Coordinate: *node.point(), Kind: kind, Name: node.Tags["name"], MaxSpeedKph: speedKph(node.Tags), Association: "unknown", SourceIDs: []string{node.key()}, Status: "mapped"}
		ways := onWays[node.ID]
		for _, w := range ways {
			c.RoadWayIDs = append(c.RoadWayIDs, w.ID)
		}
		if len(ways) > 0 {
			c.Association = "on_way"
			c.RoadRef = ways[0].Tags["ref"]
		}
		// Only one unambiguous road is safe for a single free-drive geometry.
		if len(ways) == 1 {
			for _, n := range ways[0].Nodes {
				c.RoadGeometry = append(c.RoadGeometry, *entities[osmKey("node", n)].point())
			}
		}
		// OSM direction/camera:direction commonly describes camera facing, not enforced
		// travel. Do not publish it as travel bearing without relation/road evidence.
		return c
	}
	for _, e := range entities {
		if e.Type == "node" && e.Tags["highway"] == "speed_camera" {
			cameras[e.key()] = makeCamera(e, "fixed")
		}
	}
	keys := []string{}
	for key := range entities {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		e := entities[key]
		if e.Type != "relation" || e.Tags["type"] != "enforcement" {
			continue
		}
		kind := ""
		switch e.Tags["enforcement"] {
		case "maxspeed":
			kind = "fixed"
		case "traffic_signals":
			kind = "red_light"
		case "average_speed":
			kind = "average_speed"
		default:
			continue
		}
		var from, to *Point
		var fromID, toID int64
		fromCount, toCount := 0, 0
		waySet := map[int64]bool{}
		wayRoles := map[int64]string{}
		for _, m := range e.Members {
			member := entities[osmKey(m.Type, m.Ref)]
			if m.Type == "way" && member.Tags["highway"] != "" {
				waySet[m.Ref] = true
				wayRoles[m.Ref] = m.Role
			}
			if m.Type == "node" {
				if m.Role == "from" {
					fromCount++
					from = member.point()
					fromID = m.Ref
				}
				if m.Role == "to" {
					toCount++
					to = member.point()
					toID = m.Ref
				}
				for _, w := range onWays[m.Ref] {
					waySet[w.ID] = true
				}
			}
		}
		if fromCount != 1 || toCount != 1 {
			fromID, toID = 0, 0
		}
		geometry, wayIDs, verified := orderedZone(fromID, toID, waySet, entities, wayRoles)
		if kind == "average_speed" {
			z := AverageSpeedZone{ID: e.key(), Name: e.Tags["name"], MaxSpeedKph: speedKph(e.Tags), Start: from, End: to, Geometry: geometry, GeometryVerified: verified, SourceIDs: []string{e.key()}, Status: "mapped", RoadWayIDs: wayIDs}
			for _, m := range e.Members {
				z.SourceIDs = append(z.SourceIDs, osmKey(m.Type, m.Ref))
			}
			z.SourceIDs = sortedSources(z.SourceIDs)
			if verified {
				d := cameraTravelBearing(geometry[0], geometry[1])
				z.DirectionDegrees = &d
			} else {
				result.Dataset.IncompleteZoneCount++
			}
			result.Zones = append(result.Zones, z)
		}
		for _, m := range e.Members {
			if m.Type != "node" || m.Role != "device" {
				continue
			}
			node := entities[osmKey("node", m.Ref)]
			c, exists := cameras[node.key()]
			if !exists {
				c = makeCamera(node, kind)
			} else if c.Kind != kind {
				if kind == "average_speed" && len(c.SourceIDs) == 1 {
					c.Kind = kind
				}
				if (c.Kind == "fixed" && kind == "red_light") || (c.Kind == "red_light" && kind == "fixed") {
					c.Kind = "combined"
				}
			}
			c.SourceIDs = sortedSources(append(c.SourceIDs, e.key()))
			if c.MaxSpeedKph == nil {
				c.MaxSpeedKph = speedKph(e.Tags)
			}
			if c.Name == "" {
				c.Name = e.Tags["name"]
			}
			if verified {
				if c.Association == "relation" && !sameCameraRoad(c.RoadGeometry, geometry) {
					geometryAmbiguous[c.ID] = true
				}
				c.Association = "relation"
				c.RoadGeometry = geometry
				if geometryAmbiguous[c.ID] {
					c.RoadGeometry = nil
				}
				c.RoadWayIDs = uniqueCameraWays(append(append([]int64{}, c.RoadWayIDs...), wayIDs...))
				p := projectOnRoute(c.Coordinate, geometry, cameraCumulative(geometry))
				if p.lateral <= 100 {
					d := cameraTravelBearing(geometry[p.segment], geometry[p.segment+1])
					if c.DirectionDegrees != nil && math.Abs(bearingDelta(*c.DirectionDegrees, d)) > 15 {
						directionAmbiguous[c.ID] = true
					}
					c.DirectionDegrees = &d
				}
				if directionAmbiguous[c.ID] {
					c.DirectionDegrees = nil
				}
			} else {
				// Another enforcement membership with unresolved travel geometry can
				// represent a different direction; do not retain a single chosen bearing.
				directionAmbiguous[c.ID] = true
				c.DirectionDegrees = nil
			}
			cameras[node.key()] = c
		}
	}
	for _, c := range cameras {
		result.Cameras = append(result.Cameras, c)
	}
	sort.Slice(result.Cameras, func(i, j int) bool { return result.Cameras[i].ID < result.Cameras[j].ID })
	if len(result.Cameras) == 0 && len(result.Zones) == 0 {
		return result, errors.New("missing NL camera targets")
	}
	return result, nil
}

type zoneArc struct{ to, way int64 }

// Search actual OSM node adjacency, respecting one-way direction. An ambiguous,
// disconnected, cyclic or unanchored relation stays incomplete; never interpolate.
func orderedZone(from, to int64, ways map[int64]bool, entities map[string]osmElement, roles map[int64]string) ([]Point, []int64, bool) {
	empty := []Point{}
	if from == 0 || to == 0 || from == to {
		return empty, nil, false
	}
	graph := map[int64][]zoneArc{}
	for id := range ways {
		w := entities[osmKey("way", id)]
		oneway := w.Tags["oneway"]
		if oneway == "" && w.Tags["junction"] == "roundabout" {
			oneway = "yes"
		}
		for i := 1; i < len(w.Nodes); i++ {
			a, b := w.Nodes[i-1], w.Nodes[i]
			if oneway != "-1" && roles[id] != "backward" {
				graph[a] = append(graph[a], zoneArc{b, id})
			}
			if oneway != "yes" && oneway != "1" && oneway != "true" && roles[id] != "forward" {
				graph[b] = append(graph[b], zoneArc{a, id})
			}
		}
	}
	paths := 0
	visits := 0
	seen := map[int64]bool{}
	var nodes, roadIDs []int64
	var walk func(int64, []int64, []int64)
	walk = func(n int64, path, ids []int64) {
		visits++
		if paths > 1 || visits > 50000 {
			return
		}
		if len(path) > 10000 {
			// Unsearched branches cannot establish uniqueness of another found path.
			visits = 50001
			return
		}
		if n == to {
			paths++
			nodes = append([]int64{}, path...)
			roadIDs = append([]int64{}, ids...)
			return
		}
		seen[n] = true
		defer delete(seen, n)
		for _, arc := range graph[n] {
			if !seen[arc.to] {
				walk(arc.to, append(path, arc.to), append(ids, arc.way))
			}
		}
	}
	walk(from, []int64{from}, nil)
	if paths != 1 || visits > 50000 {
		return empty, nil, false
	}
	geometry := make([]Point, 0, len(nodes))
	for _, n := range nodes {
		geometry = append(geometry, *entities[osmKey("node", n)].point())
	}
	for i := 1; i < len(geometry); i++ {
		if distance(geometry[i-1], geometry[i]) < 0.05 {
			return empty, nil, false
		}
	}
	unique := []int64{}
	for _, id := range roadIDs {
		if len(unique) == 0 || unique[len(unique)-1] != id {
			unique = append(unique, id)
		}
	}
	return geometry, unique, len(geometry) >= 2
}

func uniqueCameraWays(ids []int64) []int64 {
	sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
	out := []int64{}
	for _, id := range ids {
		if len(out) == 0 || out[len(out)-1] != id {
			out = append(out, id)
		}
	}
	return out
}
func sameCameraRoad(a, b []Point) bool {
	if len(a) != len(b) {
		return false
	}
	forward, reverse := true, true
	for i := range a {
		forward = forward && a[i] == b[i]
		reverse = reverse && a[i] == b[len(b)-1-i]
	}
	return forward || reverse
}
