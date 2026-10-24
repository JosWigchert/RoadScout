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
