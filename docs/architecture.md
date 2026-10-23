# Architecture

One SwiftUI app target, organized by feature and infrastructure responsibility. Keep views thin and inject the location provider into the driving model. Apple frameworks only; no external package dependencies.

## Planning search and destination presentation

- `PlanningLocationModel` injects a `LocationProviding` source independently of `DrivingModel`. Production uses one `CLLocationManager.requestLocation()` after search engagement/Use my location, not a continuous driving session. It stops on first fix/failure/timeout and clears its in-memory fix on background/drive entry. Approximate search positions expire after five minutes; only precise fresh fixes can preview a route.
- `PlaceProximity` recalculates distance from the current origin, sorts stably by meters or preserves provider relevance, and drops persisted distance values when no origin exists. Map center is a search bias, never represented as the user's position.
- `PlaceSearchModel` debounces/cancels queries and completion resolution, retains canonical provider order for Best match, and publishes selected places. `SearchResult` carries optional supplied phone/website data and remains compatible with older saved recents.
- `PlaceSearchViews` renders neutral reusable rows and destination details. `ContentView` swaps search/details, focuses a marker using `PlaceMapFocus`, and connects Drive here to a fresh driving fix and the existing RoadScout navigation model. `PlaceSearchPreviewFixtures` injects synthetic search/location/routing and a separate recents suite for Debug/Canvas inspection.

Phase 0 acceptance: Xcode builds the app, runs the test target, and launches without service credentials.

Phase 1 plan: explicit foreground driving sessions, Core Location and replay providers behind a main-actor protocol, deterministic speed processing, map following and recenter, persisted units, accessible driving UI. Acceptance checks cover invalid/stale GPS, conversion, smoothing, permission/session transitions, and replay cancellation. Physical GPS smoothness requires a device drive.

Future boundaries: Valhalla routing client → explicit route geometry/maneuvers → Swift navigation tracker. Camera store/evaluator and route-weather analyzer remain independent of views and each other. Do not create placeholder providers before their phase. MapKit must never calculate routes.

## Phase 1 implementation

- `LocationProviding` delivers explicit access/fix/heading/failure/completion events on the main actor. `CoreLocationProvider` constructs its CLLocationManager on the main actor (the main run loop receives delegate callbacks); its legacy delegate conformance uses `@preconcurrency`. Service availability is checked off the main thread. No authorization or tracking is started during app launch.
- `ReplayLocationProvider` reads the bundled synthetic JSON, rebases timestamps to playback time, supports cancellation, and completes instead of silently looping. No device location is used in replay.
- `DrivingModel` injects a provider factory and clock. It manages session tokens, ignores late callbacks and out-of-order samples, clears speed after five seconds without valid fixes, and stops collection when backgrounded. Session data is in memory only.
- `SpeedProcessor` is a pure value type. Valid speed requires finite nonnegative m/s, horizontal accuracy 0–50 m, speed accuracy 0–3 m/s, usable coordinates and timestamps no older than five seconds or more than one second ahead. These are initial conservative policy thresholds, not device-calibrated guarantees.
- Jitter is filtered with a time-aware exponential filter (0.4-second time constant). Changes of at least 3 m/s and readings below 0.5 m/s bypass smoothing; stopped readings show zero immediately. Invalid input clears the display and smoothing history; ordering is preserved until session reset.
- `ContentView` renders the map, injected driving state, speed and settings. No system user-location annotation is used: the same injected fix drives both live/replay annotations and the camera. Manual map interaction suspends following; recenter restores it. Map attribution stays visible.
- Units alone persist through AppStorage. Strings use SwiftUI localization or Foundation localized strings, with an English source string catalog; translations are not yet supplied.

Map tiles are managed by MapKit and are independent of GPS speed computation.

## Phase 2 implementation

Owner approved Go in Phase 2 (`phase-2.md`), superseding the original Phase-8-only backend restriction. iPhone → Traefik HTTPS → Go HTTP :8080 → existing Valhalla HTTP :8002. `routing-api.yaml` is the app-facing contract; raw Valhalla responses stay in Go. There are no third-party Go modules, database, accounts or client secrets.

- Go `RoutingProvider` abstracts the upstream. `Valhalla` validates and normalizes native units, maneuver enums, multi-leg geometry/index references, signs and speech text. API routes/capabilities/health/readiness are independently exercised with `httptest`. The shared iOS JSON fixture is checked against normalization. Server coordinates are not logged.
- `RoadScoutRoutingProvider` injects HTTP transport; validates full polyline6 geometry, legs, maneuver indices and approximate monotonic timing anchors. Engine IDs remain opaque route-instance IDs. No direct Valhalla HTTP client remains in Swift.
- `PlaceSearching` and `PlaceSearchModel` isolate MapKit place lookup, cancellation and late-result suppression. No Apple route computation.
- `NavigationTracker` is pure: segment projection, course-aware scoring, constrained progress search after matching, jitter-resistant progression, next maneuver/ETA, sustained off-route/wrong-direction detection and arrival confirmation. Initial thresholds are policy defaults requiring road calibration, not lane-level matching guarantees. Timing is explicitly maneuver interpolation, not live traffic.
- `NavigationModel` injects routing, audio and clock. It coordinates preview/selection/start/pause/end; cancels and generations requests; preserves routes during outages; uses 15-second initial reroute cooldown with failure backoff up to 120 seconds; deduplicates verbal prompts and respects multi-cue speech. No server call per GPS fix. Pausing cancels in-flight requests and speech. Resume requires a fresh fix.
- `SpeechAnnouncer` uses Apple speech synthesis, voicePrompt audio ducking and interruption stop/deactivation. No background audio/navigation capability is declared; head-unit/audio coexistence still needs device testing.
- `ContentView` renders route choices, search, navigation state and speed, and forwards lifecycle/fix events. URL/preferences persist locally, routes/search results stay in memory. Synthetic navigation replay uses the shared contract fixture and never needs the server or location permission.

Normal startup uses live mode and `AppConfiguration.routingAPIBaseURL` (`https://roadscout.joswigchert.nl`), migrating empty saved endpoints without replacing explicit overrides. `DemoTestingView` groups replay actions and advanced endpoint overrides under Settings → Demo & Testing. Demo entry/exit stops the previous driving session, cancels navigation/search work and clears route state; demo source is in-memory only. Developer replay launch flags are Debug-only. A visible Exit Demo action remains on the simulated driving map.

Camera, weather, scenic and CarPlay engines are not implemented in this phase. Future overlays attach to route ID and geometry position; missing road annotations must remain unknown. API adapters for other engines require server-side implementation/capability tests, while the core Swift contract stays stable.
