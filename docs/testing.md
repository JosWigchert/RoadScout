# Testing

## NAS deployment automation · 2026-10-27

Acceptance was recorded before implementation in `nas-deployment.md`.

- `sh -n scripts/deploy-nas.sh` and `git diff --check` passed.
- Ruby YAML parsing verified workflow dispatch targets, self-hosted/Unraid runner selection and non-cancelling target concurrency.
- Standalone Docker Compose **2.40.3** rendered `deploy/compose.nas.yaml` with `deploy/nas.env.example`. JSON assertions verified interpolated target-specific Traefik label keys, commit image tag, camera path, read-only filesystem, external networks and absent host ports.
- A temporary Docker-command shim used real Compose rendering and simulated mutation commands. Both staging/production success paths passed; build failure, container health failure, upstream readiness failure, invalid target, relative/missing environment path and invalid image-tag release ID all failed as expected.
- This Mac lacks the `docker compose` plugin; the standalone `docker-compose` executable was used for configuration checks. The NAS runner must provide the documented Compose v2 plugin and Python 3. No real container build/replacement or public HTTPS test was performed for this change. Run the workflow and public health/readiness/route checks to close those gates.

## Mounted-phone motion · 2026-10-27

Preimplementation acceptance is in `driving-motion.md`. Full Debug simulator build/test passed: 143 methods, 139 passed, 4 opt-in live skips; 169 passed parameterized executions, zero failures. Release simulator build passed. New deterministic coverage includes 30-frame movement with sparse fixes, acceleration/braking, cross-track acceleration rejection, tilted-phone coordinate transformation and magnetic gating, north-crossing gyro turns, stationary hold, handling and sensor dropout, two-second freeze, continuous GPS correction, outlier/relocation confirmation, timestamp/accuracy validation, dateline crossing, lifecycle and stale callbacks, and separation of predicted poses from measured fixes/speed.

Navigation regression coverage verifies automatic selection of the first of multiple returned routes, objective/budget/avoidance/current-origin preservation, cancellation after recovery, rejection of late responses after End, and retaining an in-flight reroute when an outside-route GPS gap restarts off-route hysteresis. Existing cooldown/backoff/outage tests remain in the full suite.

Debug `--motion-preview` injects synthetic ~50 Hz motion and 1 Hz location into the actual driving UI. The simulator appearance was inspected; a static screenshot does not establish real sensor performance or device frame cadence. Mounted-iPhone driving/handling/magnetic interference/GPS recovery/missed-turn, gestures/recenter, Reduce Motion, sensor shutdown and energy acceptance remain manual gates. No physical-device/road/CarPlay claims.

## Phase 4 verification · 2026-10-25

Acceptance was documented before implementation in `phase-4.md`. `go test -race -timeout 60s ./...` and `go vet ./...` passed. Full Debug simulator build/test passed: XCResult reports 123 methods (119 passed, 4 opt-in live skips), 149 passed parameterized executions, zero failures. Release simulator build passed.

Weather fixtures cover sample timing, full-route coverage/cap, storm-before/after arrival, thresholds, missing data, batching, interval-end boundaries, unit conversion, token/cache expiry, provider merging, endpoint status/readiness isolation, Swift decoding/transport/cancellation and state supersession. Malformed rain geometry now fails decoding instead of disappearing silently. Server-deadline expiry is tested without another request.

The hosted `:8080` Go server was rebuilt/restarted with the existing camera snapshot and experimental-routing configuration preserved. Real Utrecht–Amersfoort routing returned three tokens; each weather request succeeded with Rain Risk, 100% probability, max 4 mm/h and 5/6/7 samples. `/readyz` returned 200. The `--live-corners-preview` planning screenshot was inspected: route-card risk/time/intensity and dashed selected-route geometry/cloud marker are present. This uses a synthetic origin with real routing/weather, not physical GPS or a road test. Screenshot: temporary `roadscout-weather-planning.png`.

Physical-device, road, manual toggle/expiry appearance and broader regional forecast acceptance remain pending. KNMI is not active.

A later live simulator launch also showed **Roof Down · low forecast rain risk**, retrieval time and resolution text, with no rain overlay. The temporary `roadscout-weather-planning.png` was refreshed to this later dry state; the earlier rain screen was inspected before replacement.

## Larger detour budgets and route-preference regression · acceptance plan

- Add +85% and +100% alongside +15/+30/+50; use one shared list for the picker and persisted-value validation. The API already accepts budgets through 100%.
- Closing Directions/ending a drive clears trip selection/origin/editor/request state without silently resetting the user's objective or detour limit. Persist valid explicit choices in injected defaults; Release still offers/loads only supported profiles.
- Verify +85/+100 propagate through planning and wire payloads, survive trip teardown/relaunch and stay within the backend cap. Avoid speculative scoring changes until the reported polder journey can be reproduced with matching origin/destination/settings.

## Bottom driving dashboard and responsive heading · acceptance plan

- Driving uses one bottom card containing the current maneuver/distance, estimated arrival/remaining time/distance and End/sound controls. Preserve loading/error/retry, ready/resume and arrival states. Free drive has a compact card and an exit action.
- Remove the separate large Stop button and measured-speed-unavailable banner. Unknown measured speed remains a dash. End stops the session/GPS and returns to planning; preserve a visible synthetic-GPS indicator for demos.
- Recenter is separate, just above the bottom card at its right edge, and only appears after leaving follow mode. Full route attribution remains accessible via route information.
- Keep existing route selection/calculation/prototype behavior. Use a compact landscape dashboard so speed/limit and bottom guidance do not compete for vertical space.
- Replace compounded 1.2 s + 0.7 s + 0.85 s heading delays with a responsive 0.3 s display filter, brief source-heading interpolation, immediate actual-map compensation and 0.35 s camera easing. Reduced Motion disables interpolation. Test north wrap, response/settling and dashboard state/metrics; build/test and inspect navigation/free-drive previews.

### Verification · 2026-10-24

- Debug build/full suite with both real LAN opt-ins: **74 methods / 97 executed cases passed**, zero failures/skips. Release build/full suite (`ENABLE_TESTABILITY=YES`): **72 methods / 95 executed cases passed**, zero failures/skips.
- Five new presentation tests cover maneuver symbols/distances, remaining rather than whole-route metrics, estimated arrival, free-drive no-data behavior, loading/retry, pause/arrival, rerouting continuity and safe handling of missing/out-of-range progress. Heading tests now require a responsive step response and settling with the 0.3 s filter while retaining north-wrap/camera-compensation/invalid-sample checks.
- Installed Debug and inspected `--driving-dashboard-preview --missing-speed --panned`: bottom maneuver/arrival/time/distance/End/sound/info card, separate recenter above its right edge, speed dash and no separate GPS-speed banner or large Stop control. Inspected `--replay` free-drive screen: compact bottom card, End and demo badge, no recenter while following. Apple map attribution remained visible in these screenshots.
- Full-screen navigation/unknown-speed/recenter/landscape Canvas previews compile. Actual landscape device layout, manual End/sound/info/recenter taps, animation feel, Reduced Motion/VoiceOver/Dynamic Type extremes and physical road behavior remain hands-on checks. Static screenshots do not establish rotation smoothness or device latency.
- Full route attribution is exposed by the bottom card's information sheet; End explicitly stops GPS and returns to planning. Core route-objective calculations were not changed in this layout refinement.

## Owner-prioritized routing prototype and route names · 2026-10-24

Acceptance plan was recorded before implementation in `phase-6-prototype.md`; the requirements document records the owner's explicit early-prototype priority.

- Go race tests and vet passed. Added coverage for actual bend geometry versus vertex density, eligible road/surface/density filtering, maneuver/roundabout/U-turn exclusions, Scenic versus Corners ranking, candidate deduplication, travel-time cap, truthful no-improvement/metadata fallback, disabled capabilities and trace shape validation.
- Final Debug `build test` with `TEST_RUNNER_ROADSCOUT_LAN_SMOKE=1 TEST_RUNNER_ROADSCOUT_EXPERIMENTAL_SMOKE=1`: **69 methods / 92 executed cases passed**, zero failures/skips. Both opt-in tests exercised real app URLSession → hosted Go → NAS Valhalla; prototype metrics/road metadata decoded successfully. Naming/optional-wire fields, GPS refresh objective/budget propagation and preservation of a selected alternative near its start are also covered.
- Release `build test` with `ENABLE_TESTABILITY=YES`: **67 methods / 90 executed cases passed**, zero failures/skips. Release offers only Fastest in its UI; experimental server behavior is opt-in.
- Real responses for all three objectives validated against `routing-api.yaml`. Live Utrecht/Amersfoort and Limburg comparisons, including positive Sittard/Vaals improvement and honest no-improvement cases, are recorded in `phase-6-prototype.md`. Default Fastest still returns the existing route set without trace-analysis load.
- Inspected the `--live-corners-preview` simulator screenshot with real route geometry, road-based naming, profile/budget controls and qualifying-bend metrics. Its GPS/search input is synthetic. Manual menu/route/Drive tapping, actual road/scenery validation, accessibility and physical-device/CarPlay checks remain pending.

## Temporary hosted LAN testing · acceptance plan

- Bind the existing Go API to `0.0.0.0:8080` and verify readiness/real routing through the Mac's LAN IP (`192.168.1.157`), keeping the NAS Valhalla upstream.
- Debug defaults to `http://192.168.1.157:8080` and migrates the previously stored public default. Preserve explicit unrelated overrides. Release defaults to public HTTPS and migrates the temporary LAN value back.
- Permit HTTP only for this configured Debug host/port, including transport responses. Reject other HTTP endpoints and HTTPS-to-HTTP downgrades. Release remains HTTPS-only; scope ATS exceptions to Debug configuration and the LAN host.
- Build Debug/Release, inspect processed Info.plists and run endpoint/configuration tests. Use an opt-in live simulator request to exercise the actual URLSession/ATS path; physical iPhone local-network permission/connectivity remains a separate check.

### Verification · 2026-10-24

- Restarted the existing Go executable with `LISTEN_ADDR=0.0.0.0:8080`, upstream NAS Valhalla unchanged. Listener is on all interfaces; `http://192.168.1.157:8080/readyz` passes. The LAN sample route returns three real routes, fastest 28.056 km / 1435.199 s, no warnings.
- Ran README's Debug build/full tests with `TEST_RUNNER_ROADSCOUT_LAN_SMOKE=1`: **63 test methods / 86 executed cases passed**, zero failures/skips. XCResult confirms `optInLiveLANRouteUsesRealAppTransport()` passed, using the real iOS simulator URLSession transport to the Mac IP and decoding real routes; it was not merely a mocked/disabled test.
- Built/tested Release with `ENABLE_TESTABILITY=YES -only-testing:RoadScoutTests/LocalRoutingConfigurationTests`: all three configuration/policy tests passed. Release default/migration and HTTP rejection are verified. Debug processed Info.plist contains only the local-network/specific-IP HTTP allowance; Release contains no `NSAppTransportSecurity` exception dictionary.
- Reinstalled/launched Debug normally and confirmed persisted `routingAPIURL` became `http://192.168.1.157:8080` after preference synchronization. Explicit unrelated overrides are retained. Test hostname/port checks and redirect policy reject other HTTP hosts/ports and HTTPS downgrades.
- Physical iPhone signing, Local Network permission, Mac firewall and actual Wi-Fi connectivity remain untested; simulator transport success is not a physical-device/road claim.

## Live local Go → NAS Valhalla smoke test · 2026-10-24

- Retested the running Go API at `http://127.0.0.1:8080`, using upstream `http://192.168.1.111:8002`. `/healthz` returned `ok`; `/readyz` returned `ready`.
- Direct Valhalla `/status` succeeded and reported version **3.5.1**, `tileset_last_modified: 1792771932` and the route action. The image digest and original OSM source timestamp are not established by that status response.
- Posted `deploy/route-request.json` (Utrecht → Amersfoort, car/fastest, two alternatives, Dutch instructions requested) through local Go. Returned **three routes**, Valhalla provenance and no warnings: 28.056 km / 1435.199 s (23.9 min), 27.82 km / 26.5 min, and 39.72 km / 30.9 min. Reported polyline6 point counts: 668, 803 and 762; each had one maneuver-bearing leg.
- This supersedes the earlier local upstream-unavailable result and verifies real routing through local Go to the NAS for this request. Public HTTPS/Traefik, physical navigation, road alignment and rerouting acceptance remain separate; no device/road/CarPlay test was performed.

## Local Go startup · 2026-10-24

- Built the existing backend and started it bound to `127.0.0.1:8080` with `VALHALLA_BASE_URL=http://192.168.1.111:8002`; executable/logs are in the approved temporary directory, not source.
- Local `/healthz` and `/v1/capabilities` passed. `/readyz` and the sample `deploy/route-request.json` request returned HTTP 503 `upstream_unavailable`.
- Direct NAS `:8002/status` and local `127.0.0.1:8002/status` connections failed. Docker daemon/socket was unavailable; public HTTPS health connection timed out. Local Go startup is verified, but live Valhalla connectivity/route serving remains pending.

## Driving arrow and heading easing · acceptance plan

- Driving position is a white arrow with a dark outline/shadow and no blue circular background.
- Apply a 1.2-second circular low-pass filter to presentation heading for arrow/camera; interpolate the shortest angular path across north. Use actual map heading for relative arrow orientation, rather than filtering map-camera feedback.
- Keep GPS/course inputs to navigation unchanged. Respect Reduced Motion by disabling rotation/camera interpolation. Test wraparound, delayed response, settling and invalid/out-of-order samples; build/test and inspect a synthetic driving screenshot.

### Verification · 2026-10-24

- Debug simulator build and full Swift test suite passed. New pure heading-presentation tests cover step-response delay/settling, continuous 359°/1° wraparound, compensation against actual camera heading, invalid/out-of-order input and new-session reset.
- Installed Debug, launched `--replay`, and inspected a driving screenshot: white outlined arrow at the simulated location with no surrounding blue circle. Added standalone arrow Canvas preview; Canvas rendering was not exercised.
- Rotation uses a 0.7-second arrow animation and 0.85-second camera easing, disabled for Reduced Motion. Manual rotation/Reduced Motion interaction and physical road feel remain unverified; static screenshots do not establish animation smoothness.

Planning-row layout refinement · 2026-10-24: moved the current-location action outside the search capsule, between search and the steering-wheel button. Existing action/accessibility labels were retained. Simulator build passed; no new unit tests were added for this layout-only move.

## Full-route planner and editable origin · acceptance plan

- Remove the visible “Limit unknown” caption, retain a dash/accessible unknown value when no posted limit is available.
- Selecting a destination calculates a RoadScout/Valhalla preview from the available planning location, without requiring an active drive or pretending a planning coordinate is a GPS fix. Refresh a missing location on demand; expose loading/error/retry when no route is available.
- Render complete selected geometry, muted alternatives when returned, origin/destination markers and estimated duration/arrival/distance. Fit the entire selected route into the map area above the medium drawer, including on size changes.
- Route planner has tappable From/To rows. From opens independent place search; choosing another place recalculates from that coordinate. My location restores the physical-location origin. Editing/canceling origin preserves destination/search state; old responses cannot replace newer requests.
- Fastest is the only implemented profile. Keep profile/presentation extensible for future Scenic/More Corners/Dynamic work without claiming those routes exist.
- Driving requires fresh physical GPS and recalculates from the actual driving position, not a synthetic/custom planning origin. Add model/viewport tests, compile Debug/Release and inspect synthetic full-route/origin-editor previews. Live routing/device acceptance remains separate.

### Verification · 2026-10-24

- Debug simulator build/full Swift test suite and Release simulator build passed. New tests cover coordinate-only/custom-origin previews without GPS, no navigation without a fresh fix, My location coordinates, late obsolete responses after an origin change, missing-origin behavior, request deduplication/reset and Fastest-only profile availability.
- Viewport tests cover full-geometry fit above the sheet for wide/tall/short routes in portrait/landscape dimensions, dateline wrapping and distance-interpolated route label placement.
- Installed Debug and inspected `--route-preview`, `--custom-origin-preview`, `--origin-search-preview` and `--replay` screenshots on iPhone 17 Pro. Selected geometry and endpoints fit above the medium sheet; alternate geometry/time tags and editable endpoint rows/ETA/distance cards render; custom start marker and independent origin-search rows render. Driving screenshot confirms no visible unknown-limit caption.
- Route preview screenshots use intentionally synthetic geometry via injected Debug-only providers. They do not demonstrate live Valhalla coverage or valid road alignment. Manual origin/result/alternative/Drive tapping, keyboard/drawer gestures, live API/current GPS, actual landscape sheet behavior, accessibility and device/road/CarPlay checks remain pending.

## Place search and destination cards · acceptance plan

- Results/suggestions/recents use neutral text, category badges, comfortable row spacing and separators inside grouped surfaces; no link-style result titles.
- When the user engages search or requests location, obtain a one-shot foreground planning fix independently of the driving session. No permission request or GPS collection on ordinary launch. Distances are current-origin straight-line estimates, never invented drive times; location denial/failure leaves search usable.
- Recompute distances from current origin, sort nearby results nearest-first with stable ordering, and preserve provider relevance order without an origin. Bias place search/completions around location (or the viewed map when unavailable). Cancel superseded searches/resolutions and prevent stale results from replacing a newer selection.
- Selecting a place replaces search content with a destination card and highlights/focuses its marker. Show supplied address/category/contact details, distance, Close/Back and Drive here. Hide unavailable metadata; do not fabricate ratings, opening hours, images or ETAs.
- Drive here enters the driving UI, calculates through RoadScout/Valhalla after a fresh GPS fix and starts guidance once the route is ready. Closing detail restores the previous search results. Test proximity/cancellation/location behavior and inspect fixture-backed result/detail screens plus build/test.

### Verification · 2026-10-24

- Final Debug simulator build/full Swift test suite and Release simulator build passed using README's destination/signing settings.
- Added deterministic coverage for current-origin distance sorting, stable ties, relevance fallback, invalid coordinates, clearing stale saved distances, backward-compatible recents/contact coding, on-demand one-shot location lifecycle, denial/late callbacks, coarse-fix routing exclusion and planning-fix expiry. Existing old-search cancellation coverage also passed.
- Installed final Debug and inspected `--search-preview` and `--destination-preview` screenshots on iPhone 17 Pro. Verified neutral grouped result rows, category badges/separators, ascending distances (477 m, 1.2 km, 4.8 km, 12.1 km), nearest-sort label, destination replacing the search content, selected pin above the sheet, supplied details, Close, Drive here and Website controls. These are synthetic fixtures, not real business records.
- Full-screen and component Canvas previews compile. Live MapKit result quality/permission UI, keyboard/gesture interactions, manual result/Close/Drive tapping, Call/Website handoff, live RoadScout route-to-guidance, accessibility and physical-device/road/CarPlay acceptance remain unverified. Routing availability remains the existing live-service gate; fixture screens do not establish it.

## Animated drive mode · acceptance plan

- Entering a drive dismisses the planning sheet and keyboard, animates round speed/limit instruments into view and follows a fresh fix at driving zoom/pitch/heading. Reduced Motion removes camera motion and uses fades.
- Driving has no search/drawer; a visible Stop control returns to planning, stops GPS and pauses navigation. Recenter remains available after map gestures. Background/permission failure also restore planning.
- The circular speedometer contains only the selected-unit speed number (unknown is a dash); units remain available to VoiceOver and in Settings.
- Speed and limit circles share one 94-point diameter and the same Dynamic Type scaling/number style.
- Overspeed compares valid speed and a positive verified limit in meters/second, independent of display units. Red ring plus a warning symbol communicates overspeed without color alone. Unknown/invalid inputs never assert overspeed. Live limit remains unknown; preview-only examples demonstrate warning states.
- Preserve destination/route guidance when transitioning out of the planning drawer. Build/test and inspect planning, synthetic driving and return-to-planning screens; do not claim physical-road or Canvas interaction tests.

### Verification · 2026-10-24

- Debug simulator build and full Swift test suite passed. Added speed-display tests cover equal/below/above-limit comparisons in both units, missing/invalid limits and speeds, conversion, and stopped versus unknown readings. Release simulator build also passed before the final planning-camera restoration refinement; the final refinement was Debug build/test verified.
- Installed and inspected free-drive and navigation replay screenshots: equal-size speed/limit circles, numeric-only measured speed, close tilted heading-follow map, Stop/recenter controls, retained guidance/attribution, and no planning drawer/search.
- Added component previews for below-limit, synthetic overspeed, mph and unavailable readings. These compile; Canvas rendering and real overspeed alerts were not exercised. There is no live posted-limit source, so live overspeed remains unavailable.
- Replay completion restored the planning controls and cleared the simulated session. Manual Stop tapping, transition smoothness, live GPS, Reduced Motion, landscape/Dynamic Type extremes and VoiceOver remain hands-on checks. No physical-device/road/CarPlay verification is claimed.

## Native drawer and neutral icon controls · acceptance plan

- Replace the hand-built drag handle/height calculations with system sheet detents (compact, medium, large), system grabber, keyboard handling and scroll interaction.
- Keep the map interactive behind the sheet; keep Settings and confirmation dialogs presentable from the drawer.
- Use neutral foreground and circular system styling for Settings, Drive/Stop and recenter controls.
- Search uses a 44-point-high capsule alongside 44-point circular actions; the sheet uses a 38-point radius with 16-point horizontal content insets for coordinated nested curves.
- Compact sheet height is 76 points (twice its 38-point radius), avoiding the overly tall 92-point collapsed presentation. Verify the row remains unclipped after reducing the detent.
- Build and inspect compact and expanded simulator presentations; distinguish these checks from manual gesture/device acceptance.

### Verification · 2026-10-24

- Simulator build and existing test suite passed after the native-sheet migration.
- Installed and inspected compact planning and medium synthetic-navigation screenshots on iPhone 17 Pro: system sheet/grabber, neutral circular Settings/Drive/recenter/audio icons, retained map attribution and navigation guidance. Medium was reached programmatically when loading the demo route.
- Added medium/large drawer Canvas previews. Manual dragging, keyboard/scroll handoff, nested Settings presentation, VoiceOver and landscape sheet interaction remain hands-on checks; no such gesture/device checks are claimed.
- Follow-up curve refinement: changed search to a capsule, coordinated the sheet radius (38 points) with the circular controls (22-point radius) and 16-point horizontal inset. Simulator build passed and the compact drawer screenshot was inspected after this refinement.
- Collapsed-height follow-up: 76-point detent with equal 16-point top/bottom padding. Rebuilt and inspected the final compact screenshot: row is centered and unclipped, with the grabber retained.

Use the build/test commands in README. Tests must use deterministic inputs rather than live network providers.

## Planning layout and driving previews · acceptance checks

- Planning shows neither GPS speed nor speed limit; starting a drive shows both, and stopping hides both.
- Collapsed search and icon-only system drive button share a centered row with consistent drawer insets. Expanded search keeps the same horizontal inset.
- Driving canvas previews use a fixed simulated location/speed without GPS permissions or replay timing.
- Compile the simulator target including preview declarations; canvas rendering and hands-on accessibility checks are recorded separately.

### Verification · 2026-10-24

- README simulator `xcodebuild ... build` passed, including the driving preview provider and declarations.
- Installed and launched the updated Debug app on the booted iPhone 17 Pro simulator; inspected a planning screenshot. Speed/limit were absent; the inset search field and icon-only system drive button shared a centered row.
- Driving previews inject a fixed-clock model and synthetic fix (Utrecht, approximately 50 km/h) rather than requesting live GPS or running a timed replay. Portrait, landscape and dark variants are available. Xcode Canvas rendering was not exercised here.
- No new unit tests were added for these presentation-only changes. Device, road and CarPlay checks were not performed.

## Bundle identifier registration fix

Changed Debug/Release app identifier to `nl.joswigchert.roadscout` and the test identifier to `nl.joswigchert.roadscout.tests` after Apple rejected the former app identifier as unavailable. The README simulator build/test command with signing disabled passed. Apple Developer registration and physical-device signing must be completed by Xcode using the owner's selected team; simulator verification does not establish identifier availability on Apple's servers.

## Normal launch and demo settings · acceptance plan

- Normal launch selects live GPS, shows the ordinary map/search/speed UI and does not load fixtures or start location collection automatically.
- Default API base URL is `https://roadscout.joswigchert.nl`; migrate an existing empty setting while preserving explicit nonempty overrides.
- Settings → Demo & Testing contains both replay actions. Demo entry stops the previous session/route; navigation replay starts with the first usable simulated fix. Errors are visible.
- Exit Demo stops replay, cancels navigation/search work, clears synthetic state and restores live mode. Demo selection is not persisted across launches.
- Build and run existing iOS tests; inspect ordinary launch and explicit navigation replay in the simulator. Release builds ignore development replay launch flags. Device/live service checks remain separate.

### Verification results · 2026-10-23

- README's simulator build/test invocation with `-quiet` passed: 37 Swift methods / 51 executed cases, zero failures/skips. `xcodebuild ... -configuration Release ... build` also passed.
- Installed Release, launched with `--navigation-replay`, and inspected the ordinary Ready to drive screen: no synthetic banner/route or automatically started GPS. Release correctly ignores that developer flag.
- Installed Debug and explicitly launched navigation replay; inspected the synthetic banner, visible Exit Demo action, route/guidance, and speed. Relaunched without arguments; inspected ordinary live mode with no synthetic route/banner. These checks verify explicit replay and launch-reset behavior, not a manual tap-through of every settings/Exit Demo control.
- Default URL and empty-value migration are implemented in `AppConfiguration`/`ContentView`; nonempty saved overrides remain intact. No additional implementation-mirroring tests were added for this settings/view change.
- An HTTPS request to `https://roadscout.joswigchert.nl/healthz` timed out. Public API availability and real navigation through the NAS remain unverified. No device/road/CarPlay tests were performed.

## Phase 2 · 2026-10-23

Acceptance plan was recorded in `phase-2.md` before implementation. Existing Phase 1 device acceptance remains pending.

### Verified

- Xcode 27.0 (27A266a), iPhone 17 Pro simulator iOS 26.0.1. `xcodebuild -quiet -project ios/RoadScout.xcodeproj -scheme RoadScout -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.0.1' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build test`: passed, **37 test methods / 51 executed cases**, zero failures/skips. All Phase 1 tests remain included.
- New Swift coverage: shared contract/polyline/timing decoding; malformed shapes/indices/timing; unknown maneuver values; HTTPS endpoint validation; HTTP request and error mapping; projection/progression/arrival; jitter, invalid/stale/out-of-order fixes; sustained off-route and wrong-direction detection; GPS gap not counting as off-route evidence; voice dedup/mute/pause/fresh-fix resume; failed reroute retaining route and throttling; successful reroute replacing geometry; late cancelled response suppression; old place-search result suppression.
- `go test -race -timeout 30s ./...` and `go vet ./...` from `backend/`: passed on Go 1.27.3 (installed through Homebrew because Go was initially absent). Tests cover native synthetic Valhalla → normalized shared fixture, multi-leg global indices, miles conversion, malformed geometry/indices/totals, zero duration/unknown maneuvers, upstream request preferences and alternatives, stable errors, timeout/cancellation, API validation, health/readiness/capabilities and polyline fuzz seeds. `go test -cover -race -timeout 30s ./...` reported 72.6% statement coverage before the final MIME/body-limit hardening; no claim of an extended fuzz campaign.
- Linux `amd64` and `arm64` binaries cross-built with `CGO_ENABLED=0 GOOS=linux GOARCH=... go build -trimpath -o <temporary-output> .`; outputs kept outside source.
- `VALHALLA_NETWORK=valhalla TRAEFIK_NETWORK=proxy ROUTING_HOST=routing.example.com docker-compose -f deploy/compose.api.yaml -f deploy/compose.api.traefik.yaml config --quiet`: passed. This validates configuration, not network/container existence.
- OpenAPI YAML parsed, sample request and shared normalized response validated against its JSON Schemas using locally available PyYAML/jsonschema. No production Go dependency is introduced.
- Installed and launched `com.roadscout.RoadScout --navigation-replay` with `simctl`. Screenshots inspected during navigation and after arrival/replay completion: synthetic banner, route polyline, instruction, meter distances, ETA, mute/end controls, visible GPS speed/unknown limit, and retained Apple attribution. Arrival was shown; replay completion cleared GPS speed. Screenshots are ignored local artifacts. Speech policy is covered with an injected announcer; no physical speaker/head-unit behavior is claimed.

### Remaining acceptance gates

- `curl --connect-timeout 3 --max-time 5 -sS http://192.168.1.111:8002/status` failed to connect. No live Valhalla graph/version or real route was observed. Use the NAS smoke commands in `backend/README.md` once Europe import/build completes.
- `docker info` failed: no running Docker daemon/socket. Image build/container startup and actual Docker DNS connectivity to `Valhalla:8002` are unverified. The existing graph/import was not changed.
- Configure real `VALHALLA_NETWORK`, Traefik hostname/network/resolver; verify app → public HTTPS → Go → Valhalla. Record graph date/image digest/version, actual Dutch instruction support, real alternatives and region coverage. Only serving successful routes establishes coverage, not completion of the download alone.
- Verify real search selection → preview → navigation/reroute against the deployed API, and representative MapKit/OSM alignment. Place-search ordering is unit-tested; live Apple search UI/network lookup was not manually exercised.
- Physical GPS/course thresholds, parallel roads/complex crossings, audio interruptions/head-unit coexistence, local-network permission when using a LAN-resolved HTTPS hostname, minimum-iOS-18 runtime, landscape/Dynamic Type extremes and VoiceOver remain hands-on checks. No physical-device, road or CarPlay tests were performed. Foreground-only behavior is intentional; background/locked navigation remains Phase 5 work.

## RoadScout rename acceptance checks · 2026-10-23

- Build and run existing tests using `ios/RoadScout.xcodeproj` and the shared `RoadScout` scheme.
- Confirm the built app display name and bundle identifier are RoadScout and `com.roadscout.RoadScout`.
- Install and launch the renamed app in the simulator with synthetic replay.
- Check maintained source/configuration files for old branding; historical verification notes and generated artifacts may retain their original names.

### Verification results

- `xcodebuild -quiet -project ios/RoadScout.xcodeproj -scheme RoadScout -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.0.1' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build test`: passed. Existing 21 test methods / 29 executed cases passed, zero failures or skips.
- Built app metadata confirms display name `RoadScout` and bundle identifier `com.roadscout.RoadScout`.
- Installed and launched the renamed app with `--replay` on the iPhone 17 Pro simulator using `simctl`.
- Maintained source/configuration references use RoadScout. The original Phase 0 launch record below retains its historical identifier.
- No physical-device, road or CarPlay checks were performed for this rename.

## Phase 0 · 2026-10-22

Xcode 27, iPhone 17 Pro simulator iOS 26.0.1: `xcodebuild ... test` passed, including loading the bundled replay fixture. Installed and launched `com.roadscout.SpeedWatch` successfully using `simctl`, without credentials. An unversioned simulator destination initially failed because Xcode selected the unavailable latest OS; README pins the installed OS explicitly.

## Phase 1 acceptance plan (before implementation)

- Deterministic tests: unit conversions; invalid/negative/nonfinite readings; stale, future and out-of-order timestamps; poor horizontal/speed accuracy; responsive smoothing and stopping.
- Injected provider tests: explicit session start/stop, denied permission, late callbacks, expiry, replay completion and cancellation.
- Simulator: launch live and synthetic replay, inspect map/speed/session UI.
- Device-only pending: real GPS smoothness and heading, denial/re-enable, reduced accuracy, tunnels and energy use. Background/locked operation is deferred to Phase 5.

## Phase 1 · 2026-10-22

Environment: Xcode 27.0 (27A266a), Swift 6 mode, minimum iOS 18; iPhone 17 Pro / iOS 26.0.1 simulator. The commands in README build and test the shared scheme with signing disabled.

- Build: passed.
- Tests: passed, zero failures/skips. xcresult reports 21 test methods and 29 device executions including parameterized cases.
- `SpeedProcessorTests`: conversions; negative/nonfinite speed; poor/invalid speed and horizontal accuracy; stale/future fixes and recovery; jitter filtering; acceleration and immediate stopping; invalid-fix recovery; ordering; expiry/reset; invalid coordinate rejection.
- `DrivingModelTests`: no collection before start; explicit start/stop; late callbacks from old sessions; permission denial; stale state without callbacks; background stop; provider failure; replay completion; out-of-order data after poor accuracy; fixture loading failure; course priority.
- `ReplayLocationProviderTests` and `FoundationTests`: bundled fixture decoding, rebased timestamps, sample emission/completion and cancellation.
- Simulator smoke check: installed and launched with `--replay`. Screenshot inspected with map, synthetic position, explicit replay banner, speed 47 km/h, unknown limit and Stop control. Relaunched without arguments in dark appearance: ready state, unknown GPS speed, unknown limit and Start control rendered correctly. Apple map attribution remained visible.
- Screenshots and generated build/test outputs are local verification artifacts, not source files. Minimum-iOS-18 runtime, landscape/Dynamic Type extremes, map gesture interactions, VoiceOver and device permissions still need hands-on checks; source deployment target alone does not prove an iOS 18 runtime test.

## Physical-device / hands-on checklist (not performed)

1. Select a signing team and bundle identifier; install on an iPhone running iOS 18+.
2. Confirm no permission prompt at launch. Start live drive; try allow, deny, re-enable in Settings and reduced accuracy. No usable speed must remain unknown.
3. As a passenger or using a safe stationary setup, check position, heading and recenter after pan/zoom/rotate. Verify km/h and mph persistence, system light/dark, large text and VoiceOver labels.
4. On a real drive, assess smoothness, acceleration/braking response, stopped vehicle jitter and signal loss/tunnel recovery. Validate the initial accuracy/filter thresholds against observed data before accepting Phase 1.
5. Stop and confirm updates cease. Background or manually lock the phone: this version stops the session; return requires explicit restart. Check the active-session screen-awake behavior and restored idle behavior after stop.
6. Record battery/thermal behavior and limitations; foreground-only behavior is not background navigation. Do not mark Phase 1 fully accepted until the real-device checks pass.

## Map-first UI redesign verification · 2026-10-24

### Commands

- `xcodebuild -project ios/RoadScout.xcodeproj -scheme RoadScout -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.0.1' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build` (Debug): passed.
- Same with `-configuration Release build`: passed.
- Same with `test`: passed, **37 test methods / 51 executed cases**, zero failures/skips.
- Backend untouched; no backend commands run for this UI verification.

### Simulator inspection

- Installed the Debug build on the booted iPhone 17 Pro simulator and launched normally: ordinary live map, speed chip showing unknown GPS speed, unknown speed-limit chip, collapsed drawer with search/Start driving, and Settings gear visible while idle.
- Launched the Debug build with `--navigation-replay`: synthetic banner, route polyline, guidance strip with maneuver/distance/ETA and mute/end/recenter controls, speed chip showing simulated speed, unknown limit chip, floating Exit Demo control, and drawer states available by drag.
- Screenshots captured to local ignored artifacts (`/tmp/normal_ui.png`, `/tmp/nav_ui.png`); no screenshot files were added to the repository.

### Accessibility and reduced transparency

- Floating controls use `GlassFloatingModifier`, which switches to a solid system background when `accessibilityReduceTransparency` is enabled; glass effect is only used on iOS 26 when transparency is not reduced, with a material fallback on iOS 18–25.
- `GlassButtonStyle` now uses solid fills under reduced transparency and respects `accessibilityReduceMotion` for press scale/opacity.
- Speed and speed-limit chips provide VoiceOver labels; controls use minimum 44 pt touch targets.
- Remaining hands-on checks: VoiceOver traversal, Dynamic Type extremes, reduced-motion visual confirmation, and contrast in both appearances on device.

### Remaining gaps

- No physical-device, road, CarPlay or external HTTPS/live routing verification was performed.
- Speed-limit data remains unknown by design; no speed-limit source is implemented yet.
- Exit Demo placement was refined to a floating control during demo mode, but full tap-through of every drawer detent was not manually exercised.

## Server-driven route catalog and experimental toggle · 2026-10-24

- Go `/v1/capabilities` advertises `routingOptions` (id/title/experimental/detourOptions) and aggregate `detourOptions`; disabled experiments advertise only Fastest with no budgets. Covered by a race-enabled Go test.
- App fetches capabilities on launch and on API-URL change, builds the style and budget menus from the response, and falls back to Fastest when unreachable. Settings → Route styles → Include experimental routing hides experimental options when off. Preferences persist and reconcile with the server catalog.
- Lenient decoding: unknown objectives remain usable; missing or newer `experiment` fields fall back to neutral values instead of failing the route.
- Verification: Debug test suite with live LAN opt-ins passed **79 methods / 108 cases**, zero failures/skips. Go race tests and vet passed. Live capabilities checked against the local Go → NAS Valhalla chain. Inspected Directions showing a server-provided style label.
- Pending: manual Settings toggle/menu interaction, physical-device checks, and public deployment with `ENABLE_EXPERIMENTAL_ROUTING=1`.

## App icon · 2026-10-24

- Created an Icon Composer document (`AppIcon.icon`) with winding-road and navigation-arrow SVG layers, an automatic gradient, glass/translucency on the road and a neutral arrow shadow.
- Added a 1024×1024 PNG fallback for the iOS 18–25 deployment range and set `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` for Debug and Release.
- Verified `ictool` renders a valid 1024×1024 icon; inspected the rendered image (arrow above the road, readable at small size).
- Debug and Release simulator builds pass. Built `Assets.car` contains light/dark/tinted icon renditions plus the Icon Composer layers; both Info.plists declare `CFBundleIconName = AppIcon`.
- Home-screen screenshot capture was not completed because the simulator had no gesture tool available and the app is not on the first page. Icon correctness is verified from the rendered document and compiled asset catalog. Manual Icon Composer editing and physical-device appearance remain unchecked.

## Phase 3 camera awareness · 2026-10-24

- Acceptance plan was written before implementation in `docs/phase-3.md`.
- Go: `go test -race -timeout 60s ./...` and `go vet ./...` passed. Tests cover OSM normalization, stable IDs, connected/ordered average-speed geometry, incomplete zones, snapshot diff, no-change checks, failed-sync retention, atomic persistence, reload, missing dataset, bbox/corridor union, Valhalla way-ID confirmation and request validation.
- Live import/serving: 936 cameras and 76 zones (65 verified, 11 incomplete), source `2026-10-24T18:47:19Z`, check/change `2026-10-24T18:49:01Z`. Restarted Go with `CAMERA_DATA_DIR`; `/readyz` passed and `POST /v1/cameras` returned the snapshot with metadata/warnings. Routing remained independent.
- iOS: default Debug test run passed **99 methods / 128 cases** with 4 live-network skips; `ROADSCOUT_LAN_SMOKE=1` passed **102 methods / 131 cases** with 1 experimental skip. This includes the real `POST /v1/cameras` request and decode.
- Simulator screenshots inspected: warning strip above the driving dashboard, camera dot/beam, cluster badges with counts, and the clickable camera detail card (mapped limit + heading). Clustering is limited to 120 rendered items; cluster taps zoom into their bounds.
- Deferred/unverified: average-speed calculation, real-device road behavior, legal review per country, camera activity/completeness, and public HTTPS deployment. Synthetic camera fixtures are labeled as not real enforcement locations.
