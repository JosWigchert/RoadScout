package main

import (
	"compress/gzip"
	"context"
	"encoding/xml"
	"errors"
	"io"
	"math"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

type trafficXML struct {
	Name     string
	Attr     map[string]string
	Text     string
	Children []*trafficXML
}

func (n *trafficXML) all(name string) []*trafficXML {
	out := []*trafficXML{}
	if n.Name == name {
		out = append(out, n)
	}
	for _, c := range n.Children {
		out = append(out, c.all(name)...)
	}
	return out
}
func (n *trafficXML) first(name string) *trafficXML {
	if n.Name == name {
		return n
	}
	for _, c := range n.Children {
		if f := c.first(name); f != nil {
			return f
		}
	}
	return nil
}
func (n *trafficXML) value(name string) string {
	if f := n.first(name); f != nil {
		return strings.TrimSpace(f.Text)
	}
	return ""
}
func readTrafficXML(d *xml.Decoder, start xml.StartElement, depth int) (*trafficXML, error) {
	if depth > 64 {
		return nil, errors.New("traffic XML depth")
	}
	n := &trafficXML{Name: start.Name.Local, Attr: map[string]string{}}
	for _, a := range start.Attr {
		n.Attr[a.Name.Local] = a.Value
	}
	for {
		t, e := d.Token()
		if e != nil {
			return nil, e
		}
		switch v := t.(type) {
		case xml.StartElement:
			c, e := readTrafficXML(d, v, depth+1)
			if e != nil {
				return nil, e
			}
			n.Children = append(n.Children, c)
			if len(n.Children) > 20000 {
				return nil, errors.New("traffic XML record size")
			}
		case xml.CharData:
			n.Text += string(v)
			if len(n.Text) > 2_000_000 {
				return nil, errors.New("traffic XML text size")
			}
		case xml.EndElement:
			return n, nil
		}
	}
}

type trafficSite struct {
	Points         []Point
	Version, Index string
}
type trafficDocument struct {
	Published time.Time
	Sites     map[string]trafficSite
	Features  []TrafficFeature
	Records   int
}

func parseTrafficTime(raw string) *time.Time {
	v, e := time.Parse(time.RFC3339Nano, strings.TrimSpace(raw))
	if e != nil {
		return nil
	}
	v = v.UTC()
	return &v
}
func trafficNumber(n *trafficXML, name string) *float64 {
	raw := n.value(name)
	v, e := strconv.ParseFloat(raw, 64)
	if e != nil || !finite(v) || v < 0 {
		return nil
	}
	return &v
}
func trafficGeometry(n *trafficXML) []Point {
	if line := n.first("gmlLineString"); line != nil {
		crs := strings.ToUpper(line.Attr["srsName"])
		if crs != "" && !strings.Contains(crs, "WGS") && !strings.Contains(crs, "4326") {
			return nil
		}
		parts := strings.Fields(line.value("posList"))
		if len(parts) < 4 || len(parts)%2 != 0 || len(parts) > 20000 {
			return nil
		}
		p := []Point{}
		for i := 0; i < len(parts); i += 2 {
			lat, e := strconv.ParseFloat(parts[i], 64)
			lon, f := strconv.ParseFloat(parts[i+1], 64)
			v := Point{Latitude: lat, Longitude: lon}
			if e != nil || f != nil || !v.valid() {
				return nil
			}
			p = append(p, v)
		}
		return p
	}
	lat, e := strconv.ParseFloat(n.value("latitude"), 64)
	lon, f := strconv.ParseFloat(n.value("longitude"), 64)
	if e == nil && f == nil {
		p := Point{Latitude: lat, Longitude: lon}
		if p.valid() {
			return []Point{p}
		}
	}
	return nil
}
func setTrafficGeometry(f *TrafficFeature) {
	f.Geometry = Geometry{Encoding: "polyline6", Dimensions: 2, Count: len(f.Points), Data: encodePolyline(f.Points)}
}
func parseNDWTraffic(r io.Reader, kind, source string, sites map[string]trafficSite) (trafficDocument, error) {
	d := xml.NewDecoder(io.LimitReader(r, 128_000_001))
	doc := trafficDocument{Sites: map[string]trafficSite{}, Features: []TrafficFeature{}}
	root := false
	closed := false
	for {
		token, e := d.Token()
		if e == io.EOF {
			break
		}
		if e != nil {
			return doc, e
		}
		start, ok := token.(xml.StartElement)
		if !ok {
			if end, yes := token.(xml.EndElement); yes && end.Name.Local == "messageContainer" {
				closed = true
			}
			continue
		}
		if closed {
			return doc, errors.New("trailing traffic XML document")
		}
		if !root {
			root = true
			if start.Name.Local != "messageContainer" || !strings.Contains(start.Name.Space, "datex2.eu/schema/3/") {
				return doc, errors.New("expected DATEX II v3 messageContainer")
			}
		}
		if start.Name.Local == "publicationTime" {
			var raw string
			if e := d.DecodeElement(&raw, &start); e != nil {
				return doc, e
			}
			if t := parseTrafficTime(raw); t != nil {
				doc.Published = *t
			}
			continue
		}
		wanted := (kind == "events" && start.Name.Local == "situationRecord") || (kind == "sites" && start.Name.Local == "measurementSite") || (kind == "flow" && start.Name.Local == "siteMeasurements")
		if !wanted {
			continue
		}
		n, e := readTrafficXML(d, start, 0)
		if e != nil {
			return doc, e
		}
		doc.Records++
		if doc.Records > 100000 {
			return doc, errors.New("traffic record limit")
		}
		if kind == "sites" {
			if n.Attr["id"]==""||n.Attr["version"]==""{continue}
			index := ""
			for _, c := range n.all("measurementSpecificCharacteristics") {
				vehicle:=c.value("vehicleType")
				if c.value("specificMeasurementValueType") == "travelTimeInformation" && (vehicle==""||vehicle=="anyVehicle"||vehicle=="car"||vehicle=="carOrLightVehicle") {
					index = c.Attr["index"]
					if index != "" {
						break
					}
				}
			}
			p := trafficGeometry(n)
			if len(p) >= 2 && index != "" {
				doc.Sites[n.Attr["id"]] = trafficSite{p, n.Attr["version"], index}
			}
			continue
		}
		if kind == "events" {
			if n.Attr["id"]==""||n.Attr["version"]==""{continue}
			p := trafficGeometry(n)
			if len(p) == 0 {
				continue
			}
			status := n.value("validityStatus")
			if status == "suspended" || n.value("operatorActionStatus") == "cancelled" {
				continue
			}
			// Recurring schedules need a profile-specific interpreter: never mark them active blindly.
			if len(n.all("validPeriod")) > 0 || len(n.all("recurringTimePeriodOfDay")) > 0 {
				continue
			}
			t := strings.ToLower(n.Attr["type"])
			k, title := "incident", "Reported traffic event"
			if strings.Contains(t, "abnormaltraffic") {
				k = "congestion"
				title = "Reported congestion"
			}
			if strings.Contains(t, "roadworks") {
				k = "roadworks"
				title = "Roadworks"
			}
			management := n.value("roadOrCarriagewayOrLaneManagementType")
			if management == "roadClosed" || management == "carriagewayClosures" {
				k = "closure"
				title = "Reported closure"
			}
			if strings.Contains(t, "accident") {
				title = "Accident"
			}
			from, until := parseTrafficTime(n.value("overallStartTime")), parseTrafficTime(n.value("overallEndTime"))
			if from == nil {
				continue
			}
			f := TrafficFeature{ID: source + ":" + n.Attr["id"], SourceID: source, Kind: k, Title: title, Points: p, ValidFrom: from, ValidUntil: until, Version: n.Attr["version"]}
			// A full-road closure is bidirectional by definition. Lane/carriageway
			// restrictions without an explicit travel direction remain informational.
			if management == "roadClosed" && n.value("probabilityOfOccurrence") == "certain" && (n.value("operatorActionStatus") == "approved" || n.value("operatorActionStatus") == "implemented") {
				f.Closed = true
				f.DirectionKnown = true
			}
			// Events retain reported geometry; no direction/graph closure is fabricated.
			setTrafficGeometry(&f)
			doc.Features = append(doc.Features, f)
			continue
		}
		ref := n.first("measurementSiteReference")
		if ref == nil {
			continue
		}
		if ref.Attr["id"]==""||ref.Attr["version"]==""{continue}
		site, ok := sites[ref.Attr["id"]]
		if !ok || site.Version != ref.Attr["version"] {
			continue
		}
		for _, q := range n.all("physicalQuantity") {
			if q.Attr["index"] != site.Index {
				continue
			}
			data := q.first("basicData")
			if data == nil || !strings.HasSuffix(data.Attr["type"], ":TravelTimeData") {
				continue
			}
			travel := data.first("travelTime")
			if travel == nil {
				continue
			}
			invalidQuality:=false;for _,key:=range []string{"accuracy","numberOfInputValuesUsed"}{if raw:=travel.Attr[key];raw!=""{v,e:=strconv.ParseFloat(raw,64);if e!=nil||!finite(v)||v<=0{invalidQuality=true}}}
			if invalidQuality || data.value("fault") == "true" {
				continue
			}
			seconds := trafficNumber(travel, "duration")
			if seconds == nil || *seconds <= 0 {
				continue
			}
			normal := data.first("normallyExpectedTravelTime")
			var baseline *float64
			if normal != nil {
				baseline = trafficNumber(normal, "duration")
			}
			at := parseTrafficTime(q.value("measurementTime"))
			if at==nil {if node:=q.first("measurementTime");node!=nil{at=parseTrafficTime(node.value("timeValue"))}}
			if at == nil {
				at = parseTrafficTime(n.value("measurementTimeDefault"))
			}
			if at == nil {
				if node := n.first("measurementTimeDefault"); node != nil {
					at = parseTrafficTime(node.value("timeValue"))
				}
			}
			if at == nil {
				continue
			}
			congestion := "normal"
			if baseline != nil && *baseline > 0 {
				ratio := *seconds / *baseline
				if ratio >= 1.5 {
					congestion = "heavy"
				} else if ratio >= 1.2 {
					congestion = "slow"
				}
			}
			f := TrafficFeature{ID: source + ":flow:" + ref.Attr["id"], SourceID: source, Kind: "flow", Title: "Current travel time", Points: site.Points, ObservedAt: *at, TravelSeconds: seconds, NormalSeconds: baseline, Congestion: congestion, DirectionKnown: true, Version: site.Version}
			setTrafficGeometry(&f)
			doc.Features = append(doc.Features, f)
			break
		}
	}
	if !root || !closed || doc.Published.IsZero() {
		return doc, errors.New("traffic publication timestamp missing")
	}
	for i := range doc.Features {
		if kind == "events" {
			doc.Features[i].ObservedAt = doc.Published
		}
	}
	unique:=make([]TrafficFeature,0,len(doc.Features));seen:=map[string]int{}
	for _,f:=range doc.Features{if i,exists:=seen[f.ID];exists{prior,_:=strconv.Atoi(unique[i].Version);next,_:=strconv.Atoi(f.Version);if next>=prior{unique[i]=f}}else{seen[f.ID]=len(unique);unique=append(unique,f)}};doc.Features=unique
	return doc, nil
}

type ndwTrafficProvider struct {
	config  TrafficProviderConfig
	client  *http.Client
	sites   map[string]trafficSite
	cached  map[string][]byte
	etags   map[string]string
	sitesAt time.Time
}

func newNDWTrafficProvider(c TrafficProviderConfig, client *http.Client) *ndwTrafficProvider {
	return &ndwTrafficProvider{config: c, client: client, sites: map[string]trafficSite{}, cached: map[string][]byte{}, etags: map[string]string{}}
}
func (p *ndwTrafficProvider) Configuration() TrafficProviderConfig { return p.config }
func (p *ndwTrafficProvider) read(ctx context.Context, raw, kind string) (trafficDocument, error) {
	if raw == "" {
		return trafficDocument{}, errors.New("missing traffic feed")
	}
	req, e := http.NewRequestWithContext(ctx, "GET", raw, nil)
	if e != nil {
		return trafficDocument{}, e
	}
	req.Header.Set("User-Agent", "RoadScout/1 traffic")
	if tag := p.etags[raw]; tag != "" {
		req.Header.Set("If-None-Match", tag)
	}
	if p.config.CredentialEnv != "" {
		token := os.Getenv(p.config.CredentialEnv)
		if token == "" {
			return trafficDocument{}, errors.New("traffic credential unavailable")
		}
		req.Header.Set("Authorization", "Bearer "+token)
	}
	res, e := p.client.Do(req)
	if e != nil {
		return trafficDocument{}, e
	}
	defer res.Body.Close()
	var data []byte
	if res.StatusCode == 304 {
		data = p.cached[raw]
		if len(data) == 0 {
			return trafficDocument{}, errors.New("uncached traffic 304")
		}
	} else {
		if res.StatusCode != 200 {
			return trafficDocument{}, errors.New("traffic upstream status")
		}
		body := io.LimitReader(res.Body, 12_000_001)
		data, e = io.ReadAll(body)
		if e != nil || len(data) > 12_000_000 {
			return trafficDocument{}, errors.New("traffic compressed size")
		}
	}
	var r io.Reader = strings.NewReader(string(data))
	if len(data) > 2 && data[0] == 0x1f && data[1] == 0x8b {
		g, e := gzip.NewReader(r)
		if e != nil {
			return trafficDocument{}, e
		}
		defer g.Close()
		r = g
	}
	doc, e := parseNDWTraffic(r, kind, p.config.ID, p.sites)
	if e != nil {
		return doc, e
	}
	if len(data) > 0 && res.StatusCode == 200 {
		p.cached[raw] = data
		p.etags[raw] = res.Header.Get("ETag")
	}
	return doc, nil
}
func (p *ndwTrafficProvider) Fetch(ctx context.Context) (trafficProviderSnapshot, error) {
	out := trafficProviderSnapshot{}
	now := time.Now()
	events, eventErr := p.read(ctx, p.config.EventsURL, "events")
	if eventErr == nil && math.Abs(now.Sub(events.Published).Seconds()) < float64(p.config.MaxAgeSeconds) {
		out.Events = events.Features
		out.EventsAt = events.Published
	}
	if len(p.sites) == 0 || now.Sub(p.sitesAt) > 15*time.Minute {
		if sites, e := p.read(ctx, p.config.SitesURL, "sites"); e == nil && len(sites.Sites) > 0 {
			p.sites = sites.Sites
			p.sitesAt = now
		}
	}
	flow, flowErr := p.read(ctx, p.config.MeasurementsURL, "flow")
	if flowErr == nil && math.Abs(now.Sub(flow.Published).Seconds()) < float64(p.config.MaxAgeSeconds) {
		out.Flow = flow.Features
		out.FlowAt = flow.Published
	}
	if out.EventsAt.IsZero() && out.FlowAt.IsZero() {
		return out, errors.New("no fresh traffic publication")
	}
	if eventErr != nil || flowErr != nil {
		out.Status.Message = "Some traffic feeds unavailable; coverage is partial."
	}
	return out, nil
}
