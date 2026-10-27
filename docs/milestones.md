# Milestones

## NAS deployment workflow · 2026-10-27

Added manual staging/production GitHub Actions deployment on self-hosted Unraid, target concurrency/GitHub environments, commit-tagged local images, NAS-owned configuration and camera mounts, unique Traefik routing, Docker health/Valhalla readiness gates and deployment summaries. Single-container recreation preserves one camera writer per target. Acceptance and setup: `nas-deployment.md`. Shell syntax, YAML parsing, Compose v2 rendering and simulated success/build/health/readiness failure paths passed. Real NAS container deployment, public HTTPS and route checks remain pending.

## Mounted-phone motion and reroute recovery · 2026-10-27

Added a bounded GPS/speed + Core Motion complementary estimator, calibrated north-reference acceleration and gravity-axis gyro, handling/magnetic fallback, 30 Hz target map presentation, smooth correction, stationary hold and a two-second prediction limit. Arrow/follow-camera now share the display pose inside an isolated map view; navigation, GPS speed and camera warnings retain measured fixes. Existing automatic first-route rerouting is verified with multiple alternatives; pending reroutes cancel on real recovery and cannot resurrect ended navigation. Acceptance was recorded first in `driving-motion.md`.

Debug full tests passed (143 methods: 139 passed, 4 opt-in live skips; 169 passed parameterized executions), Release simulator build passed, and a synthetic 1 Hz GPS/50 Hz motion driving screen was inspected. Mounted-iPhone sensor orientation/calibration, handling thresholds, energy, motion smoothness and missed-turn road acceptance remain pending.

## Phase 4 planning weather · 2026-10-25

Implemented Go route tokens, bounded 15-minute memory caches, full-route sampling (max 400), Open-Meteo batching, ETA-aligned precipitation/probability, recommendations and rain-segment geometry. iOS automatically checks every alternative, presents weather in route cards, shows selected-route rain on the planning map, and provides a setting/attribution. Missing samples yield unavailable; provider intervals end at their timestamps. Weather stops on entering driving.

Verified Go race tests/vet; Debug build/full tests (123 methods: 119 passed, 4 opt-in skips; 149 passed parameterized executions); Release build; live weather on all three Utrecht–Amersfoort alternatives (Rain Risk, 100%, maximum 4 mm/h); simulator screenshot inspected. KNMI, physical-device and real-road acceptance remain open. See `phase-4.md`.

## Bottom driving dashboard and responsive heading · 2026-10-24

Consolidated maneuver/distance, arrival/time/distance and End/sound/info into a bottom card with compact landscape rendering. Removed the large standalone Stop and measured-speed-unavailable banner; recenter appears above the card only when follow is off. End exits the session to planning; route attribution is accessible through information. Tuned display heading to 0.3 s with brief source/camera easing and immediate map compensation to remove stacked lag. Debug full tests (74 methods / 97 cases) and Release full tests (72 / 95) passed, including unchanged live LAN routing checks; navigation/unknown-speed/recenter and free-drive screens were inspected. Actual road/gesture/landscape/accessibility acceptance remains pending.

## Owner-prioritized early route-objective prototype · 2026-10-24

Added opt-in Go Scenic/More Corners candidate reranking using existing Valhalla car routes, surface/class/density trace metadata, junction-aware/resampled bend scoring and detour caps. Debug Directions exposes profiles and budgets; Release remains Fastest-only. Alternatives now use factual road corridors (with correct one-based fallback alternatives), profile/budget survives fresh-GPS recalculation, and selected previews are reused when GPS still matches their start. Go race tests/vet, Debug full tests including real LAN requests, Release full tests and OpenAPI live-response validation passed. Live Utrecht and Limburg comparisons and a real-LAN-routing/synthetic-origin simulator screen were inspected. This is not Phase 6 completion; broader candidate/custom-costing work and road/device calibration remain pending, alongside earlier-phase acceptance.

Hosted LAN testing · 2026-10-24: Go now listens on all interfaces at the Mac's `192.168.1.157:8080`, using NAS Valhalla. Debug iOS defaults/migrates to that specific HTTP address; Release retains/migrates back to public HTTPS with no ATS exceptions. LAN routing and a real simulator URLSession route request passed; full Debug suite passed (63 methods / 86 cases), and three Release configuration tests passed. Debug's stored endpoint migration was verified on normal simulator launch. Physical iPhone network acceptance remains pending.

Live local routing verified · 2026-10-24: local Go health/readiness and NAS Valhalla status now pass (reported Valhalla 3.5.1). The real Utrecht → Amersfoort sample returned three normalized routes with geometry/maneuvers and no warnings. This closes the local Go-to-Valhalla connectivity/sample-route gate; public HTTPS, graph/image provenance details, iPhone navigation and road alignment/rerouting acceptance remain open.

Local backend smoke check · 2026-10-24: Go starts successfully on loopback port 8080; health/capabilities pass. Readiness and a real route request return 503 because the configured NAS Valhalla endpoint remains unreachable from this environment. Phase 2 live-routing acceptance remains open.

Driving-arrow refinement · 2026-10-24: replaced the blue position puck with an outlined white arrow, added independent 1.2-second display-heading filtering and eased shortest-path arrow rotation/camera following. Navigation inputs remain unchanged. Simulator build/full tests passed and synthetic driving appearance was inspected; manual animation/device checks remain pending.

Planning-row refinement · 2026-10-24: Search, separate circular current-location button, then Drive. Simulator build passed.

## Full-route planner and editable starting point · 2026-10-24

Selection now opens Directions, previews from physical/planning coordinates independently of an active drive, and fits full selected geometry above the sheet with muted alternative routes and selectable time labels. From opens independent origin search with My location; To can change the destination. Added estimated route cards, request deduplication/cancellation and an extensible Fastest-only profile. Driving recalculates from fresh physical GPS. Removed the visible unknown-limit caption while retaining unknown accessibility semantics. Debug/full tests and Release build verified; full-route/custom-origin/origin-search and driving screens inspected with synthetic data. Live routing and manual/device acceptance remain pending.

## Place search and destination cards · 2026-10-24

Implemented neutral grouped results/suggestions/recents, category badges, nearest/best-match sorting, recalculated straight-line distances and an independent on-demand planning location fix. Selecting a place swaps the drawer to a destination card and focuses a category marker above the sheet; supplied contacts, available route alternatives, Close and Drive here are retained. Drive here hands off to fresh-fix RoadScout/Valhalla routing and guidance. Updated permission/privacy wording and added isolated synthetic search/detail previews. Debug/full tests and Release build passed, and fixture result/detail screenshots were visually inspected. Live search/route integration and manual/device interaction acceptance remain pending.

## Animated driving presentation · 2026-10-24

Driving dismisses the planning drawer/search, enters closer pitched heading-follow, and animates equal-size circular speed/limit instruments plus Stop/recenter controls. Stopping restores planning and pauses guidance. Speed is number-only in the Settings unit; the instrument design supports a red ring plus non-color overspeed badge, with tested unit-independent comparisons. Live limits remain unknown; synthetic component previews demonstrate overspeed without supplying invented road data. Debug build/full tests and replay screens were verified; Release build passed before the final camera-return refinement. Manual transitions, accessibility and road acceptance remain pending.

## Native search drawer · 2026-10-24

Curve refinement: capsule search field, 44-point circular controls, 16-point horizontal content insets and a coordinated 38-point outer sheet radius. Follow-up build passed and compact presentation was visually inspected.

Collapsed-height refinement: reduced the compact detent from 92 to 76 points and centered its 44-point row with 16-point top/bottom insets to match the 38-point outer curve.

Replaced custom handle-only dragging and height calculations with native compact/medium/large sheet detents, system grabber and search-focus expansion. Map icon controls now have neutral circular surfaces, with accessibility-transparency and older-iOS fallbacks. Simulator build/tests passed; compact planning and medium navigation presentations were visually inspected. Manual gesture/keyboard/Settings checks remain pending.

## Planning layout and driving previews · 2026-10-24

Corrected planning-only presentation: speed/limit appear only during an active drive, the drive action is an icon-only system button, and search/header controls have consistent drawer insets. Added deterministic driving previews in portrait, landscape and dark appearance. Simulator build passed and the updated planning screen was visually inspected; Canvas and physical-device checks remain pending.

Signing refinement: app/test bundle identifiers now use `nl.joswigchert.roadscout` / `nl.joswigchert.roadscout.tests` following Apple's rejection of the previous app ID. Simulator build/tests passed; Apple team registration is not verified here.

| Phase | Status |
| --- | --- |
| 0 · Repository and build foundation | Verified: simulator build, fixture test and credential-free launch |
| 1 · Free drive | Implemented; build, deterministic tests and simulator presentation verified; physical-device acceptance pending |
| 2 · Go API + Valhalla navigation | Implemented; local Go → NAS Valhalla and simulator transport verified; public deployment/full coverage/device acceptance pending |
| 3 · Camera alerts | Planned |
| 4 · Roof Down Mode | Planning-only implementation verified in simulator/live API; KNMI and device/road acceptance pending |
| 5 · Real-world hardening | Planned |
| 6 · Scenic / Most Corners | Early owner-prioritized candidate-ranking prototype verified; custom/global optimization and field acceptance pending |
| 7 · Entitled CarPlay | Planned |
| 8 · Shared Go services | Planned |

## Phase 1 remaining acceptance gate

The requirement's real-device speed-smoothness check has not been performed. Before calling Phase 1 fully accepted, complete the physical-device checklist in `testing.md`. Background/locked driving and battery/audio hardening belong to Phase 5. Phase 2 proceeded at the owner's request with this acceptance gate still open; its implemented foreground guidance does not establish real-road reliability.

## RoadScout rename · 2026-10-23

Completed the app, project/scheme, source/test folder, requirements and deployment configuration rename. Simulator build and existing tests passed (21 methods / 29 executed cases); the renamed app installed and launched with synthetic replay. See `testing.md` for acceptance checks and results.

## Phase 2 · 2026-10-23

Normal-launch refinement: default public API is `https://roadscout.joswigchert.nl`; demo entry/advanced endpoint controls live under Settings → Demo & Testing in the same app. Demo selection is session-only; Exit Demo clears simulated state. Debug and Release builds passed, all 37 Swift methods / 51 cases passed, and simulator inspection confirmed normal launch, explicit demo with Exit Demo, and return to live mode on relaunch. Release ignores developer replay launch flags. Public `/healthz` verification timed out from this environment; deployment is not newly claimed as verified.

Go API with normalized OpenAPI contract and Valhalla adapter; NAS port 8080 and existing private Valhalla port 8002; Swift API client, cancellable place search, route/alternative previews, pure navigation tracking, voice/mute, pause/resume, arrival and rerouting with cooldown/backoff. Shared fixtures, backend race tests/vet and 37 Swift test methods / 51 executed cases passed. Navigation and arrival simulator screens inspected. Linux amd64/arm64 Go binaries cross-built and Compose configuration validated.

Live NAS Valhalla :8002 could not be reached from this environment; Docker daemon was unavailable. Europe graph completion, actual engine/version capabilities, Docker container execution, external Traefik HTTPS, real route/MapKit alignment and device audio/road checks remain acceptance gates. No later phase was implemented. See `testing.md` for exact commands/results and `backend/README.md` for deployment.


## Map-first UI redesign · 2026-10-24

Verified the combined map-first UI redesign in the simulator without changing feature logic (only compile-safe UI refinements).

- Debug and Release builds passed; all 37 Swift test methods / 51 executed cases passed.
- Normal launch and `--navigation-replay` launch inspected in the iPhone 17 Pro simulator: map-first layout, collapsed/half/expanded drawer affordance, speed and unknown-limit chips, guidance strip, and settings/Exit Demo controls.
- Accessibility/reduced-transparency assumptions reviewed; `GlassButtonStyle` refined for solid fills under reduced transparency and reduced-motion press feedback.
- Remaining gaps: physical-device/VoiceOver/Dynamic Type/reduced-motion verification, real GPS/routing acceptance, and speed-limit data source (still unknown by design). No device/road/CarPlay claim is made.

## Server-driven route styles · 2026-10-24

Route styles, titles, experimental flags and detour budgets now come from Go `/v1/capabilities`; the app has a Settings toggle for experimental styles and falls back to Fastest when capabilities are unavailable. Go-only changes can add/rename styles or adjust budgets without an app update. Experimental metadata decodes leniently so a working route is preferred over no route. Go race tests/vet and Debug tests (79 methods / 108 cases) passed; live catalog and Directions screen inspected. Physical/public deployment acceptance remains pending.

## App icon · 2026-10-24

Added a winding-road Icon Composer app icon with layered SVG assets, plus a 1024 PNG fallback for iOS 18–25 and the AppIcon build setting. Icon Composer/`ictool` rendering and Debug/Release asset compilation verified; manual Icon Composer editing and device appearance remain pending.

## Phase 3 camera awareness · 2026-10-24

Netherlands-only mapped camera awareness now runs through one Go `POST /v1/cameras` endpoint. The persistent snapshot lives in `CAMERA_DATA_DIR`, is bind-mountable for container persistence, and is reconciled by a six-hour in-process sync with atomic last-good retention. Live import produced 936 cameras and 76 average-speed zones (65 verified, 11 incomplete). The app shows clustered/clickable camera markers with directional beams, an above-dashboard warning strip, route-preview data, and camera settings/coverage. Go race tests/vet and Debug tests passed, including a live LAN camera fetch. Average-speed calculation, real-device/road checks and legal review remain pending.
