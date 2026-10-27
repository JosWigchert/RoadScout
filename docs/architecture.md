# Architecture

## Planning weather (Phase 4)

Go `weather.go` owns route-token registration, bounded memory stores, sampling/timing, recommendation and `/v1/weather`. `weather_provider.go` isolates Open-Meteo batching, UTC interval alignment and units behind a provider interface; worst-of-both merging is ready for a future KNMI adapter. Route/readiness behavior is independent of weather availability. Missing samples cannot produce a Roof Down recommendation.

Swift `Features/Weather` separates wire models, injected transport, observable request/cache state and presentation. `ContentView` loads every alternative when planning routes arrive, clears weather on endpoint changes/drive entry, and renders rain for the selected route only. No weather computation or provider-specific API access lives in views; no driving weather/audio. See `phase-4.md` and `weather-api.yaml`.

One SwiftUI app target, organized by feature and infrastructure responsibility. Keep views thin and inject the location provider into the driving model. Apple frameworks only; no external package dependencies.

## Driving presentation

`DrivingGuidancePresentation` is a pure snapshot of navigation state: current maneuver, remaining metrics, ready/loading/error/paused/arrival and temporary no-progress handling. `DrivingDashboard` renders that snapshot as one bottom card; it does not calculate routes or advance navigation. End calls the shared navigation/session teardown and returns to planning. Full attribution is in route information, and recenter is separate and conditional on follow state.

`DrivingHeadingPresentation` filters only display course (0.3 s). Source-heading updates get brief 0.15 s easing; camera following uses 0.35 s. Map-heading feedback updates the relative continuous arrow angle with animations disabled, avoiding another delayed interpolation layer. Raw GPS/course for navigation remains independent.

## Planning search and destination presentation

- `RoutePlanningModel` owns the My location/custom-place origin, edit mode, objective and detour budget. Its request key includes endpoint/objective/budget to deduplicate unchanged plans. `NavigationModel.preview(_:origin:...)` accepts planning coordinates without converting them into GPS fixes. Objective/budget persist through fresh-GPS recalculation and rerouting. A selected preview is reused only when a fresh physical fix is within 50 m of its start; otherwise it is recalculated.
- `PlaceMapFocus.routeRect` fits complete geometry into the exposed upper map viewport, including wide/tall shapes and dateline wrapping. Route labels interpolate by along-geometry distance. `RoutePlanningViews` renders editable From/To, estimated route cards and separate origin search. Release offers Fastest; Debug also offers opt-in Scenic/More Corners prototypes. Dynamic remains future work. `RoutePresentation` derives factual corridor names from supplied maneuver road names/distances rather than numbering every route.

- Go `experimentalRouter` wraps the unchanged Fastest Valhalla provider only when `ENABLE_EXPERIMENTAL_ROUTING=1`. It generates ordinary and motorway-deemphasized `auto` candidates, deduplicates geometry, enforces the travel-time cap and evaluates at most six candidates using `trace_attributes` (two metadata requests in flight per API request). `experimental.go` isolates road eligibility, uniform resampling, maneuver exclusions and bend/countryside scoring. Effective objective/metrics/fallback status are normalized into the contract; no graph files, access restrictions or alternate engine are changed. See `phase-6-prototype.md` for limits and validation.

- `PlanningLocationModel` injects a `LocationProviding` source independently of `DrivingModel`. Production uses one `CLLocationManager.requestLocation()` after search engagement/Use my location, not a continuous driving session. It stops on first fix/failure/timeout and clears its in-memory fix on background/drive entry. Approximate planning positions expire after five minutes and can supply preview coordinates; actual navigation still requires a precise fresh driving fix.
- `PlaceProximity` recalculates distance from the current origin, sorts stably by meters or preserves provider relevance, and drops persisted distance values when no origin exists. Map center is a search bias, never represented as the user's position.
- `PlaceSearchModel` debounces/cancels queries and completion resolution, retains canonical provider order for Best match, and publishes selected places. `SearchResult` carries optional supplied phone/website data and remains compatible with older saved recents.
- `PlaceSearchViews` renders neutral reusable rows and destination-detail components. `ContentView` swaps search/Directions, focuses selected geometry using `PlaceMapFocus`, and connects Drive to a fresh driving fix and the existing RoadScout navigation model. `PlaceSearchPreviewFixtures` injects synthetic search/location/routing and a separate recents suite for Debug/Canvas inspection.

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

## Server-driven route catalog

`/v1/capabilities` is the source of truth for route styles. Go advertises ordered `routingOptions` with `id`, `title`, `experimental` and per-style `detourOptions`, plus aggregate `detourOptions`. `RoutingCatalog` fetches and caches this for the current API URL; `RoutePlanningModel.apply(options:)` reconciles the persisted style/budget against it. Unknown objectives are represented by `RoutePlanningProfile`'s raw string, so new Go styles are usable without an app rebuild. Settings gates experimental styles. On fetch failure the catalog falls back to Fastest only. `RouteExperiment` decoding is intentionally lenient and never invalidates an otherwise valid route.

## Cameras (Phase 3)

`CameraStore` loads the persistent `CAMERA_DATA_DIR/snapshot.json` into an in-memory index. A background sync in the API process checks OSM every six hours, normalizes fixed cameras and connected average-speed geometry, reconciles complete snapshots by stable OSM IDs, writes atomically and retains the last known-good data on failure. `POST /v1/cameras` returns the union of a viewport and optional route corridor; route confirmation uses local Valhalla edge OSM way IDs and is conservative.

On iOS, `CameraClient` is the only camera transport. `CameraAlertModel` owns scoped fetch/cache and route fingerprints; `CameraAlertEvaluator` is pure and decides ahead/behind, direction/road evidence, zone entry and duplicate suppression. `CameraClusterer` limits rendered map items with zoom-aware counted clusters; `CameraMapContent` renders beams/zones/markers and `CameraDetailCard` presents mapped limit/heading. A shared `SpeechAnnouncer` queue lets camera cues wait for navigation speech and drop stale/obsolete warnings.
