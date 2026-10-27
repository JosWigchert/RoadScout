package main

import "encoding/json"

type CameraChanges struct {
	Added   int `json:"added"`
	Updated int `json:"updated"`
	Deleted int `json:"deleted"`
}

// Compare semantic records by stable identity, independently of source ordering/check timestamps.
func cameraChanges(before, after CameraSnapshot) CameraChanges {
	records := func(snapshot CameraSnapshot) map[string]string {
		result := make(map[string]string, len(snapshot.Cameras)+len(snapshot.Zones))
		for _, camera := range snapshot.Cameras {
			data, _ := json.Marshal(camera)
			result["camera:"+camera.ID] = string(data)
		}
		for _, zone := range snapshot.Zones {
			data, _ := json.Marshal(zone)
			result["zone:"+zone.ID] = string(data)
		}
		return result
	}
	old, next := records(before), records(after)
	var changes CameraChanges
	for id, value := range next {
		previous, exists := old[id]
		if !exists {
			changes.Added++
		} else if value != previous {
			changes.Updated++
		}
	}
	for id := range old {
		if _, exists := next[id]; !exists {
			changes.Deleted++
		}
	}
	return changes
}
