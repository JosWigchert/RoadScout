# API boundaries

Phase 2 introduces the owner-approved Go API. The iPhone calls `/v1/routes` over HTTPS through Traefik; Go listens on HTTP port 8080 and calls `http://Valhalla:8002` on the private Docker network. Raw engine JSON stays inside the server adapter.

- OpenAPI request/response/capability/error schema: `routing-api.yaml`.
- Architecture decision, engine comparison and geometry/timing semantics: `phase-2.md`.
- Deployment and smoke requests: `../backend/README.md`, `../deploy/route-request.json`.
- Shared normalized fixture: `../ios/RoadScout/Resources/route-response.json`.

All route distances are meters, durations seconds, geometry full 2D polyline6; references are global vertex indices. Optional data is unknown when absent. Swift's `RoutingProviding` is independently injected; Go's `RoutingProvider` can support later engine adapters without exposing their response formats to Swift. Only Valhalla is currently implemented.
