package main

import "testing"

func TestCameraStableIdentityDelta(t *testing.T) {
	old := CameraSnapshot{Cameras: []Camera{{ID: "a", Name: "Old"}, {ID: "gone"}}, Zones: []AverageSpeedZone{{ID: "zone"}}}
	next := CameraSnapshot{Cameras: []Camera{{ID: "new"}, {ID: "a", Name: "Updated"}}, Zones: []AverageSpeedZone{{ID: "zone"}}}
	if got := cameraChanges(old, next); got != (CameraChanges{Added: 1, Updated: 1, Deleted: 1}) { t.Fatalf("unexpected delta: %+v", got) }
	if got := cameraChanges(old, old); got != (CameraChanges{}) { t.Fatalf("unchanged snapshot has changes: %+v", got) }
	reordered := old
	reordered.Cameras = []Camera{old.Cameras[1], old.Cameras[0]}
	if got := cameraChanges(old, reordered); got != (CameraChanges{}) { t.Fatalf("ordering changed semantic records: %+v", got) }
}
