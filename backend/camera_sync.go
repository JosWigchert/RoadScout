package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// A count sentinel is mandatory: a truncated/remark-bearing query must never delete records.
// Road membership is fetched for both camera nodes and enforcement members; recursion
// supplies every node of those ways and every direct/nested relation member.
const cameraQuery = `[out:json][timeout:180];
area["ISO3166-1"="NL"][admin_level=2]->.nl;
(node[highway=speed_camera](area.nl);relation[type=enforcement][enforcement~"^(maxspeed|traffic_signals|average_speed)$"](area.nl);)->.targets;
(.targets; .targets >>;)->.members;
way(bn.members)[highway]->.roads;
(.members; .roads; .roads >;)->.all;
.all out body;
.all out count;`

type cameraFetcher interface {
	fetch(context.Context) ([]byte, error)
}
type overpassFetcher struct {
	client    *http.Client
	endpoints []string
}

func defaultCameraFetcher() *overpassFetcher {
	return &overpassFetcher{&http.Client{Timeout: 210 * time.Second}, []string{"https://overpass-api.de/api/interpreter", "https://overpass.kumi.systems/api/interpreter"}}
}
func (f *overpassFetcher) fetch(ctx context.Context) ([]byte, error) {
	var last error
	for i, endpoint := range f.endpoints {
		if i > 0 {
			select {
			case <-ctx.Done():
				return nil, ctx.Err()
			case <-time.After(5 * time.Second):
			}
		}
		req, err := http.NewRequestWithContext(ctx, "POST", endpoint, strings.NewReader(url.Values{"data": {cameraQuery}}.Encode()))
		if err != nil {
			return nil, err
		}
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		req.Header.Set("User-Agent", "RoadScout-NL-camera-import/1.0 (scheduled open-data sync; https://www.openstreetmap.org/copyright)")
		resp, err := f.client.Do(req)
		if err != nil {
			last = err
			continue
		}
		b, readErr := io.ReadAll(io.LimitReader(resp.Body, 64_000_001))
		resp.Body.Close()
		if resp.StatusCode != 200 || readErr != nil || len(b) > 64_000_000 {
			last = fmt.Errorf("Overpass HTTP %d or incomplete body", resp.StatusCode)
			continue
		}
		// Validate before fallback too, including semantic completeness checks.
		if _, err = importCameras(b); err != nil {
			last = err
			continue
		}
		return b, nil
	}
	if last == nil {
		last = errors.New("no Overpass endpoint configured")
	}
	return nil, last
}
func (s *CameraStore) sync(ctx context.Context, fetcher cameraFetcher, now time.Time) error {
	s.syncMu.Lock()
	defer s.syncMu.Unlock()
	b, err := fetcher.fetch(ctx)
	if err != nil {
		return err
	}
	next, err := importCameras(b)
	if err != nil {
		return err
	}
	previous := s.read().Dataset.SourceUpdatedAt
	if previous != nil && next.Dataset.SourceUpdatedAt.Before(*previous) {
		return errors.New("source snapshot regressed; retaining newer data")
	}
	if now.IsZero() {
		now = time.Now()
	}
	return s.publish(next, now)
}
func (s *CameraStore) runSync(ctx context.Context, fetcher cameraFetcher) {
	delay := cameraNextCheckIn(s.read().Dataset, time.Now())
	for {
		if delay > 0 {
			timer := time.NewTimer(delay)
			select {
			case <-ctx.Done():
				timer.Stop()
				return
			case <-timer.C:
			}
		}
		if ctx.Err() != nil {
			return
		}
		if err := s.sync(ctx, fetcher, time.Time{}); err != nil {
			if ctx.Err() == nil {
				log.Printf("camera sync failed; retaining last-good snapshot: %v", err)
			}
			delay = time.Hour
			continue
		}
		b, _ := json.Marshal(s.read().Dataset)
		log.Printf("camera sync completed: %s", b)
		delay = cameraNextCheckIn(s.read().Dataset, time.Now())
	}
}

func cameraNextCheckIn(d CameraDataset, now time.Time) time.Duration {
	if cameraSyncDue(d, now) {
		return 0
	}
	return 6*time.Hour - now.Sub(*d.LastCheckedAt)
}

func cameraSyncDue(d CameraDataset, now time.Time) bool {
	return d.LastCheckedAt == nil || d.LastCheckedAt.After(now) || now.Sub(*d.LastCheckedAt) >= 6*time.Hour
}
