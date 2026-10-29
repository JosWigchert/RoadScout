# Handoff to the NAS / Valhalla agent

RoadScout's owner approved NDW live traffic and will forward this to the agent managing the NAS. Preserve the existing production graph/service. Do not rebuild Europe or expose Valhalla/this bridge publicly. Start in staging and return sanitized configuration/results, never passwords/private keys.

## First return these facts

1. Existing Valhalla container image/digest and effective version (`/status` currently reports 3.5.1).
2. Effective `valhalla.json`, specifically `mjolnir.tile_dir`, `tile_extract`, `traffic_extract`, graph mount paths, UID/GID and read/write permissions. Include Docker mount configuration, excluding secrets.
3. Graph identity: SHA256/manifest of the exact base graph plus `/status.tileset_last_modified`, not merely image version. GraphIds change on graph rebuilds.
4. Available native traffic/extract tools and whether live traffic is currently loaded. Return tool help rather than guessing CLI flags.

## Native bridge to prepare in staging

Use the existing Valhalla version/headers for graph reads and traffic layout; do not guess Go/C++ bitfield ABI. Add a dedicated shared traffic volume (Valhalla reads, bridge writes) and configure `mjolnir.traffic_extract`. Validate actual mmap/hot-update behavior: renaming a replacement archive does not necessarily update existing mapped readers.

Private HTTP contract (reachable only from the Go API's Docker network):

### `GET /healthz`

```json
{"engineVersion":"3.5.1","graphVersion":"sha256:...","tilesetLastModified":1792771932,"liveTrafficReady":false,"snapshotId":"","expiresAt":"2026-10-28T18:00:00Z"}
```

`liveTrafficReady` may be true only when the configured service is actually consuming a current snapshot against the exact graph. HTTP health itself may be 200 even when no live snapshot is available.

### `PUT /v1/traffic/snapshot`

```json
{"graphVersion":"sha256:...","snapshotId":"ndw:...","expiresAt":"2026-10-28T18:03:00Z","edges":[{"graphId":"123456789","speedKph":18.0,"closed":false}]}
```

- Full replacement of the previously applied edge set; omitted edges revert to UNKNOWN, including an empty snapshot. Reject wrong graph version, unknown/out-of-range IDs, invalid values and expiry >180 s ahead.
- `speedKph:null` means unknown. Observed 0 km/h with `closed:false` must use a slow positive supported speed (e.g. 2 km/h); native zero speed denotes a closure. Only explicit `closed:true` is written as closure.
- Use version-compatible aligned/native writes and handle all relevant hierarchy levels/shortcuts. Partial/torn updates must not be published as ready.
- On success return the same health schema with the applied snapshot ID/expiry. On expiry revert written edges to unknown and report not ready, even if Go stops publishing. Add an independent watchdog/supervised failure policy.
- A graph change invalidates mappings and live readiness immediately.

## Required proof before enabling

On a small staging route pair: apply controlled slow speeds and show increased native ETA AND a changed native route; verify opposite direction unaffected; expire/clear and recover baseline; terminate updater and verify stale live data cannot continue influencing Go requests; reject wrong graph manifest. Test both confirmed closure and stopped-but-open traffic.

RoadScout will enable current-speed request options only while the bridge graph/timestamp/snapshot/expiry match. A deployment flag alone is insufficient. Return sanitized before/after requests/results, configuration/mount changes, bridge URL and graph identity. Do not enable production until these checks pass.
