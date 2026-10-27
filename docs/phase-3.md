# Phase 3 · Netherlands camera awareness

## Owner decisions and acceptance plan (before implementation)

Netherlands/open data only. Camera data comes exclusively through the existing Go server, using one `POST /v1/cameras` endpoint. The canonical snapshot is in `CAMERA_DATA_DIR`, bind-mountable at `/data/cameras`; updates survive image replacement. Background sync runs in the API process, every six hours (and on startup when due). Reconcile complete source snapshots by stable OSM identifiers; write changed snapshots atomically and retain last-known-good data on failure. Maintain last successful check separately from last dataset change and source snapshot time. Ordinary routing must not depend on camera availability.

Source plan: OpenStreetMap speed-camera nodes and enforcement relations, including average-speed sections and connected road geometry. Record ODbL/source/import timestamps and report unresolved zone geometry. Official open publications are cross-checks until their coordinate data and reuse terms are verified. OSM mirrors are not independent coverage; historical violation statistics are not current camera coordinates. Do not sum overlapping node/relation counts or claim complete coverage/active enforcement.

Average-speed zones require connected, ordered road geometry and direction. Never draw a straight connector as an enforced zone. Show known incomplete records/markers honestly; do not use incomplete geometry for zone warnings. Actual average-speed measurement is deferred.

## Contract

`POST /v1/cameras` accepts `bbox` (south/west/north/east), optional `route` (`encoding: polyline6`, `data`, `corridorMeters`) and returns `dataset`, `cameras`, `averageSpeedZones`, `truncated`, `warnings`. Map queries return visible records and route-corridor records as a union; route relevance is additional metadata, not an assertion that all nearby cameras enforce the driver's lane. Metadata includes NL coverage, version, lastCheckedAt/lastChangedAt/sourceUpdatedAt, sources, incomplete-zone counts and stale status. Camera records carry stable id, coordinate, kind, optional maxSpeedKph/directionDegrees/road geometry/OSM way IDs, source IDs and mapped status. Zones carry optional start/end, geometry, geometryVerified and provenance. No per-request user-location logging.

## App behavior

Persist fetched responses with endpoint/query scope and timestamps for cached-area warnings through network gaps; server storage alone is not phone-offline support. Load markers on the route-planning map and while driving. Display average-speed zones with purple geometry/entry-exit markers. A compact warning strip sits above the driving dashboard. Warnings use ahead/along-route distance and direction/road evidence; ambiguous nearby records may be visible but do not trigger confident spoken warnings. Unknown speed remains unknown and camera-specific limits do not become a universal posted-limit feed.

Use one speech coordinator for maneuver/camera cues: prioritize imminent navigation, discard obsolete queued camera warnings, and honor master mute plus camera-audio settings. Keep data, matching, audio and rendering injected/testable. Average speed tracking is later work; no trip traces sent to Go for that future feature.

## Focused acceptance checks

- Complete import normalizes nodes/relations/directions; no duplicate device for the same OSM entity; adjacent distinct carriageways are not proximity-merged. Valid zone geometry is connected/ordered; incomplete zones are labeled.
- Successful no-change sync updates lastCheckedAt without changing data version; partial/failed/remark-bearing source responses and invalid disk writes keep the old snapshot. Background sync never blocks routing startup. Mounted snapshot reloads after restart.
- Camera endpoint validates inputs, serves bbox/route union, reports truncation and missing-data state, includes zones crossing a viewport even when endpoints are outside. Route readiness remains independent.
- Seeded/replayed fixes warn ahead, not behind/opposite direction or an unrelated parallel road with known road evidence. Ambiguous matches suppress speech; duplicates are suppressed; expired GPS cannot advance alerts. Route changes invalidate cached route positions.
- Cached responses retain coverage/age and do not imply uncached/global coverage. Settings show last check/source/coverage and warning/audio controls.
- Inspect route-planning markers/zones and the above-dashboard warning strip using explicit synthetic fixtures; build app and run targeted backend/evaluator/cache/audio checks. Never claim real-device/road/CarPlay acceptance from fixtures.

## Verification · 2026-10-24

- Go race tests and vet passed. Camera tests cover import normalization, connected zone ordering, incomplete geometry, stable-ID snapshot diff, no-change checks, failed/partial retention, atomic storage, missing-data behavior, route way-ID confirmation, bbox/corridor union and endpoint validation.
- Live final-code import: **936 cameras**, **76 average-speed zones** (**65 verified**, **11 incomplete**). Source snapshot `2026-10-24T18:47:19Z`; successful check/change `2026-10-24T18:49:01Z`; dataset not stale at publication. Snapshot persisted in the mounted `CAMERA_DATA_DIR` and served after restart.
- `POST /v1/cameras` NL bbox returned 936 cameras, 76 zones and 65 verified zones (~829 KB), with the incomplete-zone warning. `/readyz` remained ready and routing stayed independent. `/v1/capabilities` advertises NL camera metadata.
- App tests: default run **99 methods / 128 cases**, 4 live-network skips, zero failures. With `ROADSCOUT_LAN_SMOKE=1`: **102 methods / 131 cases**, 1 experimental skip, zero failures, including the real single-endpoint camera fetch.
- Simulator inspection: camera dot with white ring and directional beam; above-dashboard warning strip with mapped limit; zoom-aware cluster badges with counts; clickable detail card showing mapped limit and heading. Fixtures are synthetic, not real enforcement locations.
- The sync runs in the API process every six hours, retries hourly after failure, and keeps last-known-good data. Docker persists the host-mounted folder across image updates; the container root filesystem remains read-only while the camera mount is writable by UID/GID 10001.
- Not verified: physical-device GPS/road behavior, legal review per jurisdiction, actual camera-data completeness/activity, average-speed calculation (deferred), and real iOS ↔ public HTTPS deployment.

### Route confirmation note

Live route-corridor checks (Utrecht ↔ Amersfoort) returned 104 viewport records and 3/1 corridor-near records, with **0 `confirmed`** for those directions. The nearby records either lacked OSM way identity, sat on a different/opposite carriageway way, or had an incompatible enforcement bearing. This is the intended conservative behavior: cameras remain visible on the route map, but speech requires matching OSM way identity plus direction evidence. It does not indicate that no cameras exist on the route; it reflects available OSM attribution. No false confirmation was forced.
