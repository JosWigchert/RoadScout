# Phase 2 · Valhalla navigation

**Historical pre-amendment plan:** the owner subsequently approved a small Go API, reuse of their existing Europe graph, and Traefik TLS termination. The current plan, contract and acceptance checks are in `phase-2.md` and `routing-api.yaml`; those supersede the direct-Valhalla-client/new-import steps below. Retained for the original acceptance context.

## Implementation plan (before implementation)

1. Supply a pinned upstream Valhalla scripted Docker service, persistent regional OSM graph, health/smoke checks, and local TLS plus existing-Traefik HTTPS recipes. Document graph coverage, versions, resources and update procedure.
2. Add Sendable routing models, bounded polyline6 decoding, and an injected async HTTPS-only Valhalla client. Use auto costing, alternatives and supported toll/highway preferences; never substitute Apple routing.
3. Add pure Swift GPS-to-route projection, maneuver progress, remaining distance/time, arrival, and sustained off-route detection with hysteresis/cooldown. Keep geometry computation off the UI actor.
4. Add cancellable destination place search, route previews/alternatives, start/end navigation, a guidance banner with ETA, voice prompts, routing endpoint/preferences settings, and explicit outage feedback that retains a loaded route.
5. Add deterministic protocol/fixture tests for decoding, malformed responses, request options, service failures, stale async results, progress, arrival, jitter and reroute suppression. Build/test the app and inspect available simulator flows.

## Acceptance checks

- An origin/destination route is fetched from self-hosted Valhalla over HTTPS, decoded and displayed on MapKit; available alternatives are selectable.
- Replayed fixes advance maneuvers/distance/ETA; sustained divergence requests one rate-limited reroute. Stops, new destinations and late responses cannot replace a newer session.
- Denied/stale GPS never advances navigation; service timeout/network loss keeps loaded geometry and clearly states rerouting is unavailable. No offline-routing claim.
- Turn prompts are deduplicated and audio respects foreground session stop/mute.
- Compose validates; attempt local container/import/route verification if the runtime is available. Record exact runtime blockers instead of claiming a deployed service.
- Simulator builds/tests execute; physical driving, MapKit/OSM alignment, audio interruptions and externally reachable HTTPS remain explicit manual gates until actually checked.

Phase 1's physical-device gate remains pending; proceeding with Phase 2 implementation at the owner's request does not mark that gate passed.
