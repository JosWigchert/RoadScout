# Data sources

## Open-Meteo · active Phase 4 provider

Weather data by [Open-Meteo.com](https://open-meteo.com/), CC BY 4.0. Go requests forecast precipitation at estimated route passage times using `minutely_15=precipitation` and hourly precipitation probability. Precipitation is mm over the preceding 15 minutes, converted ×4 to mm/h; probability covers the preceding hour. Provider timestamps mark interval ends. Native 15-minute availability is regional (including Central Europe/North America); elsewhere values can be interpolated hourly data. Probability is coarser ensemble guidance, not a point-level certainty.

The hosted free API is subject to non-commercial terms and usage limits distinct from the data license; review before public/commercial distribution. Configurable server URL supports a future approved/self-hosted provider. KNMI radar is deferred pending a server-side key; no KNMI adapter/coverage is claimed. Any missing forecast sample yields unavailable. See `phase-4.md`.

Current map display: Apple MapKit, subject to Apple terms, with system attribution retained. Replay samples are synthetic development fixtures, not recorded trips or verified road geometry.

Phase 2: place search uses Apple MKLocalSearch. Route geometry and guidance come from the owner's self-hosted Valhalla through the RoadScout Go API. The configured deployment is `ghcr.io/gis-ops/docker-valhalla/valhalla:latest`, Europe graph in progress; actual engine version, image digest, OSM date and successful coverage checks have not been observed from this environment. Do not equate downloaded map files with a completed/serving graph. API timing is approximate maneuver interpolation; no live traffic feed is asserted. The API returns OSM attribution; operator must retain source/license records. API/provider research sources and compatibility notes are in `phase-2.md`.

Future camera datasets must record license, attribution, region coverage, import time and source update time. OSM is ODbL; review derived database obligations before redistribution. WeatherKit requires account capability/terms/quota verification. Worldwide UI support is not a claim of worldwide routing or camera coverage.

## Phase 3 camera data · 2026-10-24

Camera locations are imported from OpenStreetMap in the Netherlands: `highway=speed_camera` nodes plus `type=enforcement` relations for `maxspeed`, `traffic_signals` and `average_speed`. Imported average-speed sections retain connected/ordered road geometry and direction; unresolved sections are counted and labeled, not connected with invented straight lines. The Go server serves the normalized snapshot; iOS does not bundle or independently fetch camera sources.

License: ODbL-1.0, © OpenStreetMap contributors. Coverage is Netherlands-only and incomplete. Mapped records do not establish that a device is active. The two Overpass endpoints used for sync are mirrors of one source, not independent coverage. CJIB/OM average-speed publications are useful cross-checks but do not provide verified current coordinate geometry. Proprietary camera databases are excluded.
