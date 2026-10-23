# Phase 2 · routing and foreground navigation

## Approved architecture / acceptance plan (before implementation)

Owner approved introducing a small Go API now, overriding the original Phase-8-only Go restriction. Swift calls the engine-independent `/v1/routes` contract over HTTPS. Traefik terminates TLS; Go listens on HTTP :8080, NAS LAN address 192.168.1.111:8080, and calls http://Valhalla:8002 on the existing user-defined Docker network. Reuse the owner's `ghcr.io/gis-ops/docker-valhalla/valhalla:latest` Europe build. Do not start another graph import. The mutable image tag is not a verified engine version.

Implementation sequence: contract and fixtures → Go adapter/server → Swift client/search/preview → pure navigation tracker/coordinator/audio → verification and documentation.

Acceptance checks:
- Go fixture tests: multi-leg index remapping, maneuver normalization, units, malformed upstream results, no-route/unavailable/timeouts, request validation and cancellation. Race-enabled tests and vet.
- Shared fixture: Go validates and Swift decodes the same bundled normalized response, including polyline and timing anchors.
- Swift deterministic tests: segment projection, progression/arrival, GPS jitter/staleness, off-route hysteresis, reroute throttling, cancellation/outdated responses, outage retaining route, audio deduplication.
- Simulator build/test; route preview and replay through navigation UI; search and public API connectivity where available.
- Live deployment: verify `/readyz`, calculate a real route via Go/Valhalla, record engine/graph provenance and MapKit alignment. Mark pending if NAS/graph is unavailable.
- No claim of device/road/CarPlay verification. Phase 1 real-device acceptance stays pending. Foreground navigation pauses on background and requires explicit resume with fresh GPS.

## Contract decisions

See `routing-api.yaml` for the wire schema. JSON camelCase; meters, seconds, WGS84 named coordinates; full 2D polyline6. All indices are global zero-based vertex indices in one route geometry. An interval [a,b] covers edges a through b-1, sharing endpoints with neighbors. Arrival may have a zero-length interval. Flatten legs with boundary deduplication and remap every index. Do not simplify after indexing.

Route IDs identify immutable route instances; new calculations/reroutes get new IDs. Guidance IDs are unique within a route. Timing anchors use elapsed seconds, include endpoints, and identify maneuver interpolation explicitly (not live traffic or per-edge measured timing). Delay at a position can use repeated indices with increasing time. Missing optional annotations mean unknown, never false/zero. No speed limit is inferred from travel speed.

Preferences are soft `avoid`/`neutral`; unsupported hard exclusions are rejected. Alternatives are up to N additional routes. Returned instruction language is actual upstream language. Unknown enum values degrade to unknown, not decoder failure. Mandatory profile/objective are car/fastest initially. Invalid explicit options fail instead of silently changing semantics.

Optional future annotations (speed limits, surface, lanes, signs, elevation), scenic metrics and camera/weather overlays must reference the same route ID/geometry. They are not fabricated in Phase 2. Road-name and typed sign metadata already travel with maneuvers when available; phase-specific capabilities advertise only implemented fields.

## Research / engine mapping

| Concept | Valhalla | OSRM | GraphHopper | openrouteservice |
| --- | --- | --- | --- | --- |
| Geometry | leg polyline6 | route/step polyline5/6 or GeoJSON | encoded precision configurable; optional elevation | encoded or GeoJSON |
| Distance/time | km or mi / seconds | meters / seconds | meters / milliseconds | meters / seconds |
| Instructions | numeric types; written + alert/pre/post verbal phases | structured type/modifier, needs narrative renderer | numeric sign + localized text + intervals | numeric types + text + waypoint intervals |
| Legs | breaks create legs | waypoint legs | via instructions / intervals | segments between waypoints |
| Detail | signs; lane data depends on version/options | intersections/lanes, segment annotations | configured path details | requested extras indexed to geometry |

OSRM segment durations exclude turn duration; do not treat them as a complete passage timeline. Valhalla maneuver time is a useful baseline for approximate sampling. Upstream defaults and version-specific metadata require inspection against the actual deployed version. Toll/highway avoidance in Valhalla is a preference, not a guaranteed exclusion. Initial implementation supports Valhalla only; other adapters need tests and capability declarations before activation.

Sources researched 2026-10-23:
- https://valhalla.github.io/valhalla/api/route/api-reference/
- https://project-osrm.org/docs/v5.24.0/api/
- https://github.com/graphhopper/graphhopper/blob/master/docs/web/api-doc.md
- https://giscience.github.io/openrouteservice/api-reference/endpoints/directions/
- https://giscience.github.io/openrouteservice/api-reference/endpoints/directions/instruction-types
- https://giscience.github.io/openrouteservice/api-reference/endpoints/directions/extra-info/
