# Milestones

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
| 2 · Go API + Valhalla navigation | Implemented and fixture/simulator-verified; live NAS/Europe graph, Docker image execution and device acceptance pending |
| 3 · Camera alerts | Planned |
| 4 · Roof Down Mode | Planned |
| 5 · Real-world hardening | Planned |
| 6 · Scenic / Most Corners | Planned |
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
