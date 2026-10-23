# Data sources

Current map display: Apple MapKit, subject to Apple terms, with system attribution retained. Replay samples are synthetic development fixtures, not recorded trips or verified road geometry.

Phase 2: place search uses Apple MKLocalSearch. Route geometry and guidance come from the owner's self-hosted Valhalla through the RoadScout Go API. The configured deployment is `ghcr.io/gis-ops/docker-valhalla/valhalla:latest`, Europe graph in progress; actual engine version, image digest, OSM date and successful coverage checks have not been observed from this environment. Do not equate downloaded map files with a completed/serving graph. API timing is approximate maneuver interpolation; no live traffic feed is asserted. The API returns OSM attribution; operator must retain source/license records. API/provider research sources and compatibility notes are in `phase-2.md`.

Future camera datasets must record license, attribution, region coverage, import time and source update time. OSM is ODbL; review derived database obligations before redistribution. WeatherKit requires account capability/terms/quota verification. Worldwide UI support is not a claim of worldwide routing or camera coverage.
