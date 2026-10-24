package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"time"
)

type CameraSource struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	License     string `json:"license"`
	Attribution string `json:"attribution"`
	URL         string `json:"url,omitempty"`
}
type CameraDataset struct {
	Version             string         `json:"version"`
	Coverage            string         `json:"coverage"`
	LastCheckedAt       *time.Time     `json:"lastCheckedAt,omitempty"`
	LastChangedAt       *time.Time     `json:"lastChangedAt,omitempty"`
	SourceUpdatedAt     *time.Time     `json:"sourceUpdatedAt,omitempty"`
	Sources             []CameraSource `json:"sources"`
	IncompleteZoneCount int            `json:"incompleteZoneCount"`
	Stale               bool           `json:"stale"`
	Changes             *CameraChanges `json:"changes,omitempty"`
}
type Camera struct {
	ID                  string   `json:"id"`
	Coordinate          Point    `json:"coordinate"`
	Kind                string   `json:"kind"`
	Name                string   `json:"name,omitempty"`
	MaxSpeedKph         *float64 `json:"maxSpeedKph,omitempty"`
	DirectionDegrees    *float64 `json:"directionDegrees,omitempty"`
	RoadRef             string   `json:"roadRef,omitempty"`
	RoadGeometry        []Point  `json:"roadGeometry,omitempty"`
	RoadWayIDs          []int64  `json:"roadWayIDs,omitempty"`
	Association         string   `json:"association"`
	SourceIDs           []string `json:"sourceIDs"`
	Status              string   `json:"status"`
	RouteDistanceMeters *float64 `json:"routeDistanceMeters,omitempty"`
	RouteLateralMeters  *float64 `json:"routeLateralMeters,omitempty"`
	RouteMatch          string   `json:"routeMatch,omitempty"`
}
type AverageSpeedZone struct {
	ID               string   `json:"id"`
	Name             string   `json:"name,omitempty"`
	MaxSpeedKph      *float64 `json:"maxSpeedKph,omitempty"`
	Start            *Point   `json:"start,omitempty"`
	End              *Point   `json:"end,omitempty"`
	Geometry         []Point  `json:"geometry"`
	GeometryVerified bool     `json:"geometryVerified"`
	DirectionDegrees *float64 `json:"directionDegrees,omitempty"`
	SourceIDs        []string `json:"sourceIDs"`
	Status           string   `json:"status"`
	RoadWayIDs       []int64  `json:"roadWayIDs,omitempty"`
	RouteStartMeters *float64 `json:"routeStartMeters,omitempty"`
	RouteEndMeters   *float64 `json:"routeEndMeters,omitempty"`
	RouteMatch       string   `json:"routeMatch,omitempty"`
}
type CameraSnapshot struct {
	Dataset CameraDataset      `json:"dataset"`
	Cameras []Camera           `json:"cameras"`
	Zones   []AverageSpeedZone `json:"averageSpeedZones"`
}

func emptyCameraSnapshot() CameraSnapshot {
	return CameraSnapshot{Dataset: CameraDataset{Coverage: "NL", Stale: true, Sources: []CameraSource{{"osm", "OpenStreetMap", "ODbL-1.0", "© OpenStreetMap contributors", "https://www.openstreetmap.org/copyright"}}}, Cameras: []Camera{}, Zones: []AverageSpeedZone{}}
}

// Published snapshots are immutable. Readers copy records before adding query metadata.
type CameraStore struct {
	mu       sync.RWMutex
	syncMu   sync.Mutex
	dir      string
	snapshot CameraSnapshot
}

func newCameraStore(dir string) (*CameraStore, error) {
	s := &CameraStore{dir: dir, snapshot: emptyCameraSnapshot()}
	b, err := os.ReadFile(filepath.Join(dir, "snapshot.json"))
	if errors.Is(err, os.ErrNotExist) {
		return s, nil
	}
	if err != nil {
		return s, err
	}
	var candidate CameraSnapshot
	if err = json.Unmarshal(b, &candidate); err != nil {
		return s, err
	}
	if candidate.Dataset.Coverage != "NL" || candidate.Dataset.Version == "" || candidate.Cameras == nil || candidate.Zones == nil {
		return s, errors.New("invalid camera snapshot")
	}
	s.snapshot = candidate
	return s, nil
}
func (s *CameraStore) read() CameraSnapshot {
	s.mu.RLock()
	defer s.mu.RUnlock()
	result := s.snapshot
	result.Dataset.Stale = cameraDatasetStale(result.Dataset, time.Now())
	return result
}
func cameraDatasetStale(d CameraDataset, now time.Time) bool {
	for _, stamp := range []*time.Time{d.LastCheckedAt, d.SourceUpdatedAt} {
		if stamp == nil || now.Sub(*stamp) > 24*time.Hour || stamp.After(now.Add(5*time.Minute)) {
			return true
		}
	}
	return false
}
func (s *CameraStore) publish(next CameraSnapshot, now time.Time) error {
	old := s.read()
	changes := cameraChanges(old, next)
	next.Dataset.Changes = &changes
	data, err := json.Marshal(struct {
		Cameras []Camera
		Zones   []AverageSpeedZone
	}{next.Cameras, next.Zones})
	if err != nil {
		return err
	}
	hash := sha256.Sum256(data)
	next.Dataset.Version = hex.EncodeToString(hash[:])
	now = now.UTC()
	next.Dataset.LastCheckedAt = &now
	next.Dataset.LastChangedAt = &now
	if old.Dataset.Version == next.Dataset.Version {
		next.Dataset.LastChangedAt = old.Dataset.LastChangedAt
	}
	next.Dataset.Stale = cameraDatasetStale(next.Dataset, now)
	b, err := json.Marshal(next)
	if err != nil {
		return err
	}
	if err = os.MkdirAll(s.dir, 0750); err != nil {
		return err
	}
	f, err := os.CreateTemp(s.dir, ".snapshot-*")
	if err != nil {
		return err
	}
	name := f.Name()
	defer os.Remove(name)
	if _, err = f.Write(b); err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	if err = os.Rename(name, filepath.Join(s.dir, "snapshot.json")); err != nil {
		return err
	}
	s.mu.Lock()
	s.snapshot = next
	s.mu.Unlock()
	return nil
}
