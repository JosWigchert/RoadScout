# RoadScout routing, NL camera and Roof Down weather API · Phases 2–4

Small standard-library Go service. No accounts, database, external packages, or per-GPS-update API. Routing provider selection is server-side; only Valhalla is implemented. Weather provider selection is server-side; only Open-Meteo is active. The app consumes the normalized contracts in `../docs/routing-api.yaml` and `../docs/weather-api.yaml`.

## Local development

Go 1.23+ (verified toolchain recorded in `docs/testing.md`):

```sh
go test -race -timeout 60s ./...
go vet ./...
VALHALLA_BASE_URL=http://192.168.1.111:8002 LISTEN_ADDR=127.0.0.1:8080 go run .
```

Weather defaults to `OPEN_METEO_BASE_URL=https://api.open-meteo.com/v1/forecast` and `WEATHER_CACHE_TTL=15m`; no key is required. Both may be overridden for local fixtures or a self-hosted Open-Meteo deployment.

The LAN upstream above is a development override only and requires Valhalla to publish that host port. On the NAS use `http://Valhalla:8002` on its shared Docker network. Default listener is `:8080`; `ROUTING_PROVIDER` is `valhalla`. No secret or TLS key is required in Go: Traefik handles public HTTPS. Release iPhone builds accept HTTPS API URLs only; the temporary Debug build permits the specifically configured Mac LAN HTTP endpoint.

For current iPhone LAN prototype testing, run `ENABLE_EXPERIMENTAL_ROUTING=1 VALHALLA_BASE_URL=http://192.168.1.111:8002 LISTEN_ADDR=0.0.0.0:8080 go run .` and use `http://192.168.1.157:8080`. The Debug app is configured for that Mac IP; the iPhone must be on the same LAN and grant Local Network permission. Omit the experimental flag for Fastest-only behavior. See the root README for configuration/reversion and the opt-in real URLSession tests.

## Deploy on the NAS

From the repository root, set the name of the **existing user-defined Docker network** containing the Valhalla container/alias `Valhalla`:

```sh
export VALHALLA_NETWORK=your-existing-valhalla-network
export ROUTING_HOST=roadscout.joswigchert.nl
export TRAEFIK_NETWORK=proxy
export TRAEFIK_CERT_RESOLVER=letsencrypt
docker compose -f deploy/compose.api.yaml -f deploy/compose.api.traefik.yaml config
docker compose -f deploy/compose.api.yaml -f deploy/compose.api.traefik.yaml up -d --build
```

Use the hostname, TLS resolver and `websecure` entrypoint from your actual Traefik setup. Go joins both networks; if they are the same external network, use that name for both variables. Go publishes NAS port **8080**, leaving Valhalla on **8002**. No graph volume or Valhalla image is changed. The supplied Go-only Compose file works without the Traefik overlay for LAN smoke tests.

```sh
curl --fail http://192.168.1.111:8080/healthz
curl --fail http://192.168.1.111:8080/readyz
curl --fail http://192.168.1.111:8080/v1/capabilities
curl --fail http://192.168.1.111:8080/v1/routes \
  -H 'Content-Type: application/json' --data-binary @deploy/route-request.json
```

Repeat the route request via your public HTTPS hostname before configuring it in the app. `/healthz` checks Go; `/readyz` checks Valhalla status, **not** full graph coverage. Only a successful route confirms a particular area. Europe download/build must finish first. Record the actual container image digest, Valhalla version and OSM graph timestamp; `latest` is mutable. GIS-OPS's Docker repository is archived; do not infer modern optional fields solely from that tag.

## Behavior and limits

Experimental objectives are disabled by default. Set `ENABLE_EXPERIMENTAL_ROUTING=1` locally or in Compose to advertise/accept `scenic` and `more_corners`. They support two waypoints, fastest-baseline distances up to 250 km, and optional integer `maxExtraDurationPercent` (0–100, default 30; UI 15/30/50). Up to six deduplicated candidates are evaluated using `trace_attributes`, with at most two metadata requests in flight per API request. Ordinary Fastest requests do not trigger this work. All routing remains `auto` car costing with legal access/restrictions unchanged.

Scenic is a paved low-road-density proxy, More Corners is qualified-bend density; the pool is reranked, not globally optimized. `route.experiment` records effective objective, baseline/detour, estimates and status. Missing metadata or no meaningful within-budget improvement returns a clearly marked Fastest fallback with a warning. Full prototype acceptance/limits: `../docs/phase-6-prototype.md`.

- Car/fastest; 2–10 stops; 0–2 additional routes; BCP-47-style instruction language.
- Toll/motorway/ferry preferences are neutral or soft avoid. Unsupported options are rejected. No Apple routing or fallback engine.
- HTTP request body 16 KiB; upstream body 8 MB; each geometry at most 100,000 points. Four concurrent graph requests; Traefik rate/body limits; upstream timeout 15 seconds. Cancellation follows client disconnects. Go's public route deadline is 16 seconds.
- No request coordinates or bodies are logged by Go. Review proxy access logging separately. Responses use no-store.
- Full 2D polyline6 with global indices, route-instance IDs, normalized written/verbal maneuvers, actual instruction language, signs/names when supplied, snapped waypoint endpoints, approximate timing anchors.
- Timing is scaled maneuver interpolation, not per-edge timing or a claim of live traffic. Unknown speed limits/lane data are not fabricated. Optional future annotations require adapter capability support.
- HTTPS is terminated by Traefik; internal HTTP is intentional. The binary runs non-root with a read-only container filesystem. Health endpoints are operational, not an authentication mechanism; this is an owner-operated MVP service.

Fixture tests use a synthetic native Valhalla response and the **same normalized JSON bundled in iOS** at `ios/RoadScout/Resources/route-response.json`. These are not recorded real-road routes. Other engines require new adapters and contract tests, not Swift changes for the core route format.

## Phase 3 · Netherlands cameras

Contract: [`../docs/cameras-api.yaml`](../docs/cameras-api.yaml). The locked app wire is preserved, including optional geometric route positions, road identity/geometry, all three dataset timestamps, warnings and truncation. Standard library only; no accounts or paid/unverified feeds.

### Import and persistence

The API process schedules a complete NL source check every six hours, starting asynchronously when due at startup. Failed checks retry hourly. Primary: `https://overpass-api.de/api/interpreter`; secondary: `https://overpass.kumi.systems/api/interpreter`, with a five-second fallback backoff, explicit importer User-Agent, 210-second HTTP timeout and 64 MB response limit. These are mirrors of one OSM source, not independent coverage. Query: NL `highway=speed_camera` nodes and `type=enforcement` relations with `maxspeed`, `traffic_signals` or `average_speed`; recursively include members, highway ways containing target/member nodes, and all their nodes. OSM attribution/ODbL-1.0 is included in every response. Neither mapped status nor timestamps imply an active device or complete coverage.

`CAMERA_DATA_DIR` defaults to `data/cameras` relative to the binary's working directory; Compose sets `/data/cameras`. `snapshot.json` is the canonical persistent snapshot. All normalized records are reconciled by stable OSM entity IDs, never proximity; device memberships in multiple relations enrich the same node record, while different nodes stay separate. Complete snapshots can remove disappeared IDs. A required terminal count sentinel, matching entity totals, all referenced nodes/members, and source timestamp are validated before publication. Malformed, truncated, remark-bearing, empty-target, missing-reference and older-source responses retain the last good snapshot and check time. Sync uses a serialized writer, same-directory temporary file, file fsync and atomic rename; readers continue using the immutable previous snapshot until the write succeeds.

`lastCheckedAt` is the completion time of a successful check/publication, `lastChangedAt` changes only with normalized records, and `sourceUpdatedAt` is Overpass's `timestamp_osm_base`. Version is a deterministic normalized-record SHA256; no-change source checks update check/source metadata without version churn. `stale` means either the successful check or source snapshot timestamp is missing, older than 24 hours, or more than five minutes in the future. A successful check of an old mirror therefore does not hide source staleness. Sync is due when the saved successful check is missing, at least six hours old, or in the future; a fresh normal check suppresses startup fetching even when its source is stale, avoiding excessive public-source retries. Missing/corrupt/unwritable storage is independent of routing startup, `/healthz` and `/readyz`; cameras return an empty dataset with a warning until imported. Existing loaded data remains available when later syncs fail. Back up the mounted directory if retaining it across host replacement matters.

Average-speed geometry follows actual OSM node adjacency, entry-to-exit order, one-way restrictions and explicit forward/backward member roles. Only one connected, nondegenerate directed path is verified; ambiguous, disconnected, multiply anchored or incomplete relations keep known markers and empty geometry with `geometryVerified:false`. No straight from/to connector is generated. The resolver uses relation road members and ways actually containing member nodes, so missing intermediate road membership can deliberately leave a zone incomplete. Camera-facing `direction` tags are never treated as enforced travel headings. Reliable camera bearings come from local ordered relation road geometry; conflicting directions remain unknown. A single unambiguous on-way road or resolved relation road is attached for conservative free-drive alignment. Relations without a mapped device node do not invent a device coordinate; average-speed relation records are preserved regardless.

### Camera queries

```sh
curl --fail http://127.0.0.1:8080/v1/cameras \
  -H 'Content-Type: application/json' \
  --data '{"bbox":{"south":50.7,"west":3.2,"north":53.6,"east":7.3}}'
```

Add `"route":{"encoding":"polyline6","data":"<route geometry>","corridorMeters":150}` to request the **union** of viewport and route-corridor records. Crossing zone segments count even when both endpoints are outside the viewport. Limits: 256000-byte body, 10000 route vertices, 1000 km geometric route length, corridor `(0,5000]` meters, four concurrent camera requests, and 5000 total returned records. Ordinary bbox queries never call Valhalla. Route identity has a three-second sub-deadline within the eight-second camera-query deadline; incomplete deadline-limited results set `truncated` and a warning.

Route positions use cumulative haversine distances on the submitted polyline and the same local segment projection as Swift `NavigationTracker.traveledMeters`; they are not scaled to Valhalla's reported route distance. Lateral projection alone yields `nearby`. `confirmed` additionally requires the associated OSM way ID on the locally projected Valhalla `trace_attributes` edge, <=50 m lateral separation and compatibility with a known travel heading. If enforced direction is unknown, local road geometry must establish road-axis alignment within 30 degrees; absent road geometry cannot confirm. Projections clamped beyond the route origin/end cannot confirm. Invalid trace edge indices and failed metadata responses are discarded. Zones additionally need verified geometry, monotonic forward positions, identity at every vertex and segment midpoint, and forward segment orientation within 60 degrees of the route. Missing/resampled trace shape or absent way IDs yields a warning and conservative `nearby` results. This is road evidence, not lane/activity certainty; consumers should still apply approach/direction/alert rules. No coordinates, route request bodies or per-user location logs are written by Go.

### Build/start and mounted deployment

From `backend/`, build or perform a standalone import without starting/replacing any HTTP process:

```sh
go build -o /tmp/roadscout-camera-api .
CAMERA_DATA_DIR="$PWD/data/cameras" /tmp/roadscout-camera-api --camera-sync-once
CAMERA_DATA_DIR="$PWD/data/cameras" ENABLE_EXPERIMENTAL_ROUTING=1 \
  VALHALLA_BASE_URL=http://192.168.1.111:8002 LISTEN_ADDR=0.0.0.0:8080 \
  /tmp/roadscout-camera-api
```

The owner must stop/restart the existing server when integrating; implementation verification does not replace that process. Omit the experimental flag for Fastest-only routing. The one-shot flag uses the same importer/store, emits dataset metadata and exact record/zone counts, and exits nonzero on failure. Do not run a second writer against an actively syncing data directory; normal operation is one API container.

Compose bind-mounts `${CAMERA_DATA_HOST_DIR:-../backend/data/cameras}` read/write to `/data/cameras`; the root filesystem remains read-only. Provision the host directory writable by container UID/GID **10001** before starting (for example, `mkdir -p backend/data/cameras` and `sudo chown 10001:10001 backend/data/cameras`, or use an explicitly provisioned NAS path via `CAMERA_DATA_HOST_DIR`). The generated `backend/data/` tree is ignored; imported production records are not repository fixtures. Dockerfile already copies all `*.go`, including the camera implementation, without copying imported data.

### Acceptance and verification notes

The prewritten Phase 3 acceptance plan is in `../docs/phase-3.md`. Backend-focused checks in `camera_test.go` cover entity-ID normalization without proximity merging; camera-facing direction rejection; ordered/reversed-way zone paths; disconnected/ambiguous/wrong-way/member-role conflicts; incomplete markers; successful no-change vs source-time vs record-change semantics; concurrent readers; persistent reload; failed/partial/remark-bearing/regressed imports and disk publication errors; secondary source fallback; viewport/corridor union and crossing zones; geometric route arclength; parallel-road and opposite-direction downgrades; missing way identity; truncation; request validation; and camera-independent readiness/routing, including an in-flight blocked background import. These are synthetic server tests, not iOS/device/road/CarPlay acceptance.

Verified in this implementation session:

- Integration follow-up 2026-10-25: hosted `:8080` was subsequently rebuilt/restarted with the existing camera data and experimental routing preserved. All three live Utrecht–Amersfoort routes returned weather (100%, max 4 mm/h); readiness passed. Final race tests include interval-end alignment and any-missing-sample unavailability; vet passed.

- `go test -race -timeout 60s ./...` passed (final run 6.545 s), including existing routing/prototype tests; `go vet ./...` passed. The final run also followed a conservative fix rejecting graph searches that hit the path-depth bound before uniqueness is established. The Go timeout flag requires `-timeout 60s` or `-timeout=60s`.
- Built the final standalone binary at `/var/folders/m2/hzwknc_n5b52pswh2kt8mm5w0000gn/T/opencode/roadscout-camera-api`. No existing HTTP process was restarted or replaced.
- A real NL import into `/var/folders/m2/hzwknc_n5b52pswh2kt8mm5w0000gn/T/opencode/roadscout-camera-import` produced **936 normalized camera records**, **76 average-speed relation records**, **74 verified zones**, and **2 incomplete zones**. Overpass source snapshot: **2026-10-24T18:28:52Z**; saved check/change timestamp: **2026-10-24T18:29:59.943178Z**; version `a4914bfaa06ba1a47e285678d861e0405471a14d30c90ab0a85d793536e56456`. Counts describe that import, not current complete/active NL enforcement coverage.
- That first live import preceded the final refinements for member-role conflicts, conflicting travel directions, degenerate geometry, and successful-check completion timing. An initial refined-binary refresh failed after public-source fallback with a secondary timeout; the old snapshot remained intact. The bounded follow-up refresh below subsequently succeeded.
- `docker compose -f deploy/compose.api.yaml config` could not execute because this environment's Docker CLI lacks a working Compose plugin (`unknown shorthand flag: 'f'`). Container/mount deployment remains an owner-side verification step. Only the camera mount and environment were added to the existing Compose setup; its read-only root is preserved.

Imported production data exists only in the approved temporary directory, not in the repository. The backend README carries the backend verification notes for this parallel task; root/app documentation and other phase documents were outside the assigned editing scope.

### Final conservative review and successful refined import

The follow-up review tightened unknown-direction confirmation to require actual local road-axis alignment, rejected beyond-endpoint clamping and invalid trace edge ranges, and added zone-segment midpoint identity/orientation checks. An unresolved additional enforcement membership now clears a previously selected camera travel bearing. Source age participates in `stale` independently from successful check time, and future check timestamps cannot postpone startup sync. Wire fields/enums are unchanged. Regression tests exercise these cases through the real in-process HTTP handler as well as the lifecycle/store; no hosted HTTP process or Xcode process was started/restarted.

One bounded final-code import operation (normal primary/secondary policy, no retry loop) succeeded:

- **Snapshot to use:** `/var/folders/m2/hzwknc_n5b52pswh2kt8mm5w0000gn/T/opencode/roadscout-camera-import/snapshot.json`.
- **`CAMERA_DATA_DIR`:** `/var/folders/m2/hzwknc_n5b52pswh2kt8mm5w0000gn/T/opencode/roadscout-camera-import`.
- **Binary:** `/var/folders/m2/hzwknc_n5b52pswh2kt8mm5w0000gn/T/opencode/roadscout-camera-api`.
- **936 cameras; 76 average-speed zones; 65 verified and 11 incomplete.** Incomplete records retain known markers without synthesized enforced geometry.
- Source snapshot: **2026-10-24T18:47:19Z**. Successful check/change time: **2026-10-24T18:49:01.682096Z**. Version: `201489967a9faed7812d630aa3f995c5aabb3a30eb6fd07c9afba7844299d60c`. Dataset reported `stale:false` at publication.
- Focused regression command: `go test -race -timeout 60s -run TestCamera ./...` (passed, 1.421 s). The saved-data contract check `CAMERA_SNAPSHOT_CHECK_PATH=<absolute snapshot.json> go test -race -timeout 60s -run TestCameraImportedSnapshotContract -v .` also passed (1.816 s), confirming the persisted counts, full NL bbox response without fabricated route evidence, stable normalized version after reload, and no-change publication/startup-due state. It performs no network fetch, opens no listener, and writes only a disposable test-store copy.

At integration, use the above data directory with the binary and the existing listener/Valhalla/experimental environment settings. A fresh successful check skips startup source work until six hours have elapsed. The temporary path is usable now; for long-term NAS deployment provision the documented writable bind mount and carry the snapshot into it as part of owner-controlled deployment. Root filesystem and UID requirements are unchanged.

## Phase 4 · Roof Down route weather

Contract: [`../docs/weather-api.yaml`](../docs/weather-api.yaml). The locked app wire is preserved: each route in `/v1/routes` gains an opaque `weatherToken` and `weatherExpiresAt`, and `POST /v1/weather` accepts only `{routeToken, departureAt}`. Route geometry is never resent by the app.

### Configuration and lifecycle

- `OPEN_METEO_BASE_URL` defaults to `https://api.open-meteo.com/v1/forecast`; `WEATHER_CACHE_TTL` defaults to `15m`. Both are optional. No API key, account or paid SDK is used. Attribution: "Weather data by Open-Meteo.com" (CC BY 4.0).
- `WEATHER_CACHE_TTL` is parsed with Go duration syntax and must be positive; an invalid value fails startup.
- Route tokens use `crypto/rand` and are valid for **15 minutes**. The in-memory token store is bounded (512 entries) and holds only encoded polyline6 geometry, duration and timing anchors. The weather response cache is bounded (1024 entries) and keyed by token plus departure instant; expired entries are evicted lazily.
- Weather work is isolated from routing: a missing/failing weather provider cannot affect `/healthz`, `/readyz` or `/v1/routes`. Route token registration is in-memory only and cannot fail the route response.
- No coordinates, route bodies or user/trip identifiers are logged by Go. Responses use `no-store`.

### Sampling and ETA

- Spacing = `max(2 km, 5 min × average speed, route length ÷ 400)`; start and end are always included; total samples are capped at **400** while still covering the whole route (long routes widen spacing, never truncate).
- ETA uses the route's timing anchors when present, otherwise linear distance interpolation. This matches the iOS route-card estimate (`elapsedSeconds(at:)`).
- Coordinates are sent to Open-Meteo in batches of at most **50**. Each batch requests `minutely_15=precipitation`, `hourly=precipitation_probability`, `timezone=UTC` and a forecast range sufficient for the route (at most 16 days).

### Recommendation and segments

- A sample is rain risk when probability ≥ **30%** and intensity ≥ **0.1 mm/h**. Any risk sample → `rain_risk`; otherwise `roof_down`.
- Open-Meteo `minutely_15.precipitation` is an accumulation in mm over 15 minutes; Go converts it to mm/h (× 4) to apply the intensity floor. Probability is hourly, so it is coarser than intensity; both are aligned to the sample ETA in UTC. This resolution difference is intentional and documented, not smoothed into a false precision.
- A missing probability, a missing/out-of-range precipitation or probability bucket, or any missing sample makes the route recommendation `unavailable` with `summary` omitted. A warning (`weather_samples_missing`) explains partial gaps; Go never asserts dry from incomplete coverage.
- Provider timestamps end the preceding 15-minute precipitation / hourly probability interval. Alignment uses `(timestamp - interval, timestamp]`, not the following interval.
- The summary is the worst available sample by maximum intensity, then maximum probability. Contiguous risk samples are merged into segments; segment bounds are the midpoints between risk and non-risk samples (so a single-sample shower still has positive-length geometry), and the route geometry between those bounds is sliced and re-encoded as polyline6.
- The provider interface already merges multiple providers with a worst-of-both helper (`worstForecast`): when two providers cover a sample, the higher probability and higher intensity win; missing coverage from one provider does not override another provider's usable value. Only Open-Meteo is active; a KNMI adapter can be added without changing the wire contract.

### Endpoint example

```sh
# Use the weatherToken returned by /v1/routes.
curl --fail http://127.0.0.1:8080/v1/weather \
  -H 'Content-Type: application/json' \
  --data '{"routeToken":"<token>","departureAt":"2026-10-24T12:00:00Z"}'
```

Status mapping: `400 invalid_request` for malformed/unknown-field/missing input, `410 weather_token_expired` for an unknown or older-than-15-minute token, and `503 weather_unavailable` when the provider cannot be reached or returns no usable forecast for the whole route. `413`/`415`/`429` mirror the other endpoints.

### Acceptance and verification notes

Synthetic tests in `weather_test.go` cover:

- a deterministic storm fixture before vs after the passing time (rain risk with segments vs roof down), a dry route, missing/majority-missing samples → unavailable (summary omitted), timezone conversion, cache expiry, token expiry, sampling spacing/start/end/400 cap, timing-anchor ETA, batching at 50 coordinates, Open-Meteo alignment and units, missing probability/out-of-range times, the worst-of-both merge helper, the full endpoint contract (including capabilities.weather), no geometry resend (unknown `geometry` field rejected), and routing/readiness isolation from weather failure.

Verified in this implementation session:

- `go test -race -timeout 60s ./...` passed (final run 6.603 s); `go vet ./...` passed. The Go timeout flag requires `-timeout 60s` or `-timeout=60s`.
- A live check used a separately built binary on `127.0.0.1:18080` with a temporary camera directory, the existing Valhalla endpoint and default Open-Meteo settings. The existing server on `:8080` was **not** restarted or replaced.
- `POST /v1/routes` returned **3 routes**, each with a 64-character weather token and `weatherExpiresAt`. The first route (28,056 m, 1,435 s) then produced `POST /v1/weather` → **200**, recommendation `rain_risk`, **5 samples**, **5 rain-risk samples**, max probability **100%**, max intensity **3.2 mm/h**, worst at `2026-10-24T22:48:24Z` near `52.1247, 5.3468`, and **1 segment** spanning `0–28025.4 m` with polyline6 geometry. No warnings were returned. These counts describe that one live route/forecast, not a claim about current weather or device/road behaviour. A second live run with the final binary on `127.0.0.1:18081` produced the same shape: 3 routes, tokens present, **200**, `rain_risk`, **5 samples**, **5 rain-risk samples**, **1 segment**, max probability **100%**, max intensity **3.2 mm/h**, no warnings.
- Open-Meteo quirk observed: the live forecast for that route was wet at every sample, so the single segment covered nearly the whole route; probability was hourly (100%) while intensity came from 15-minute accumulation (0.8 mm per 15 minutes → 3.2 mm/h). This is expected from the documented resolution difference.

Deployment note: the weather service is enabled by default in `main`; existing Compose files need no change because the defaults are built in. Adding `OPEN_METEO_BASE_URL` or `WEATHER_CACHE_TTL` to a Compose environment is optional. The owner must restart the existing container to pick up this binary; this session did not do so.
