# Testing

## Full-route planner and editable origin · acceptance plan

- Remove the visible “Limit unknown” caption, retain a dash/accessible unknown value when no posted limit is available.
- Selecting a destination calculates a RoadScout/Valhalla preview from the available planning location, without requiring an active drive or pretending a planning coordinate is a GPS fix. Refresh a missing location on demand; expose loading/error/retry when no route is available.
- Render complete selected geometry, muted alternatives when returned, origin/destination markers and estimated duration/arrival/distance. Fit the entire selected route into the map area above the medium drawer, including on size changes.
- Route planner has tappable From/To rows. From opens independent place search; choosing another place recalculates from that coordinate. My location restores the physical-location origin. Editing/canceling origin preserves destination/search state; old responses cannot replace newer requests.
- Fastest is the only implemented profile. Keep profile/presentation extensible for future Scenic/More Corners/Dynamic work without claiming those routes exist.
- Driving requires fresh physical GPS and recalculates from the actual driving position, not a synthetic/custom planning origin. Add model/viewport tests, compile Debug/Release and inspect synthetic full-route/origin-editor previews. Live routing/device acceptance remains separate.

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
