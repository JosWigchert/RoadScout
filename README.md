# RoadScout

iPhone driving companion built with SwiftUI and MapKit. See `RoadScout_Requirements_OpenCode.md` for the product specification.

## Open and run

Open `ios/RoadScout.xcodeproj`, select the **RoadScout** scheme and an iPhone simulator, then Run. Minimum deployment target: iOS 18. No dependencies, service credentials or project generator are needed.

For a physical iPhone, select your development team in Signing & Capabilities and use an available bundle identifier. Location permission is requested when engaging search/Use my location for nearby places, or when starting a live drive—not on launch.

The app bundle identifier is `nl.joswigchert.roadscout` (tests: `nl.joswigchert.roadscout.tests`). Automatic signing still requires registration with your selected Apple development team.

## Command-line verification

From the repository root (Xcode 27 used during development):

```sh
xcodebuild -project ios/RoadScout.xcodeproj -scheme RoadScout -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.0.1' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
xcodebuild -project ios/RoadScout.xcodeproj -scheme RoadScout -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.0.1' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO test
```

The same commands are suitable for a macOS CI runner with that simulator installed; adjust the destination for other machines.

## Layout

- `ios/`: native app and deterministic unit tests.
- `backend/`: small Go routing API and deterministic adapter/server tests.
- `deploy/`: Go NAS/Traefik deployment and optional standalone Valhalla development stack.
- `docs/`: architecture, milestones, verification and data obligations.

### SwiftUI previews

The search drawer uses the native resizable sheet with compact, medium and large detents. Focusing search expands it for the keyboard; the map remains interactive. **Drawer · medium** and **Drawer · expanded** previews expose the larger layouts. Map icon controls use neutral circular system glass surfaces (solid circular fallbacks on older iOS/reduced transparency).

The search capsule and circular drive control share a 44-point height; 16-point insets and a coordinated 38-point outer sheet radius keep the nested curves consistent. The compact drawer is 76 points tall, centering the row with equal top/bottom spacing.

Open `ios/RoadScout/App/ContentView.swift` and enable Xcode's Canvas. Alongside the planning previews, **Driving · simulated 50 km/h**, **Driving · landscape**, and **Driving · dark** use a fixed synthetic location/speed through the injected location provider, without requesting GPS permission. Units follow the saved app preference. Planning hides speed/limit; the steering-wheel icon starts a drive.

MapKit displays maps and searches places. The app requests routes from a small Go API; its initial provider is self-hosted Valhalla. See `docs/phase-2.md` and the OpenAPI contract in `docs/routing-api.yaml`.

### Search and place details

- Type a shop, place or address. Suggestions and resolved places use grouped rows with category icons, neutral titles and separated address/distance subtitles.
- A one-shot planning location enables **Nearest first** sorting and current-origin distances without entering driving mode. **Best match** preserves Apple's result order. Without a location, search is biased to the viewed map and distances are omitted; saved distances are never reused. Displayed distances are straight-line estimates, in the selected unit system.
- Tap a result to replace the drawer with a destination card and highlight its pin above the sheet. The card shows supplied category/address, distance and available phone/website actions. Close returns to search results. Ratings, opening hours, business photos and travel times are not invented.
- **Drive here** opens driving mode, calculates through RoadScout/Valhalla after a fresh GPS fix and starts guidance when the route arrives. A route preview/alternatives may be available in the card when a precise fresh planning fix and routing service are available.
- `ios/RoadScout/App/PlaceSearchPreviewFixtures.swift` provides full search/list/detail Canvas previews with synthetic places and isolated recents. Debug simulator arguments `--search-preview` and `--destination-preview` show the same screens with stubbed search/location/routing; Release ignores these flags. The component previews live in `PlaceSearchViews.swift`.

## Free drive (Phase 1)

Driving now has its own animated map mode: the planning sheet/search dismiss, the map moves into closer tilted heading-follow, and equal-size circular speed/limit instruments appear. The speed circle contains only the number in your selected km/h or mph setting. **Stop** returns to planning; the location-arrow button restores follow after map gestures. Reduced Motion uses fades and immediate camera changes.

The overspeed design uses a red ring and an exclamation badge when valid measured speed exceeds a verified limit. **No live posted-limit source is connected yet**, so the app currently shows an unknown limit and never invents an overspeed warning. `Features/Driving/DrivingInstruments.swift` includes below-limit, synthetic overspeed, mph and unavailable previews. The driving and limit circles share a 94-point diameter and Dynamic Type scaling.

- Tap **Start driving**, then allow location access to display your position and GPS speed. Stop ends location/heading updates and clears the reading.
- Drag/zoom/rotate the map to explore. Tap the location arrow to recenter and resume heading-follow mode.
- Open **Settings** to choose km/h or mph. Units persist locally and initially follow the device locale.
- To try it without GPS, open **Settings → Demo & Testing → Start free-drive demo**. The labeled 15-second replay includes acceleration, GPS errors and stopping. Tap **Exit Demo** to stop it and restore live mode. Demos do not persist across app launches.
- Unknown speed shows **—**, never an invented zero. Speed limit remains explicitly unknown.
- Appearance follows the system. Active sessions keep the screen awake; manual locking/backgrounding stops the session. Restart explicitly on return. Background navigation is deferred to Phase 5.

For an automated Debug simulator preview, add `--replay` to the scheme's launch arguments, or use (Release builds ignore replay launch flags):

```sh
xcrun simctl launch --terminate-running-process booted nl.joswigchert.roadscout --replay
```

## Verification status

Phase 2 implementation is fixture/simulator-verified: **37 Swift test methods / 51 executed cases passed**, Go race tests and vet passed, and synthetic navigation/arrival screens were inspected. Live NAS routing, Docker execution, external HTTPS and physical-device acceptance remain pending. Deployment instructions: `backend/README.md`.

RoadScout rename verified on 2026-10-23: the renamed project builds, all 21 test methods pass (29 executed cases), and `com.roadscout.RoadScout` installs and launches in the simulator with synthetic replay.

Phase 0 is verified. Phase 1 is implemented and simulator-verified: build succeeds, 21 test methods pass (29 executed cases including parameterized inputs), and light/replay plus dark/idle screens were inspected. **Phase 1's real-device acceptance is still pending.** No physical-device, road or CarPlay testing has been performed. See `docs/testing.md` for the device checklist and `docs/milestones.md` for the roadmap.

## Navigation (Phase 2)

1. Deploy Go on your NAS using `backend/README.md`. Defaults: HTTP **:8080**, upstream **http://Valhalla:8002**. Traefik supplies the app-facing HTTPS hostname. Direct LAN testing uses **http://192.168.1.111:8080**.
2. The app defaults to **https://roadscout.joswigchert.nl**; no server entry is needed for normal use. Set toll/motorway preferences in Settings if desired. An optional endpoint override and reset-to-default action live under **Settings → Demo & Testing**. Existing nonempty overrides are preserved; empty saved values migrate to the default.
3. In planning mode, search a place/address and select a result. Its destination card and map marker appear. Review supplied details and any available route preview/alternatives; tap **Drive here**. Allow location if needed. Guidance starts after a fresh driving fix and a successful RoadScout route response.
4. Speed stays visible. Guidance is spoken unless muted. Rerouting requires sustained off-route evidence and uses cooldown/backoff. If Go/Valhalla is unreachable, the loaded route stays in memory; no new route can be calculated.
5. **End navigation** returns to free drive. **Stop driving** or backgrounding pauses guidance and GPS; restart driving and explicitly resume navigation with a fresh fix.

To try navigation without a server, use **Settings → Demo & Testing → Start navigation demo**. Replay and navigation start automatically; no GPS permission or server is needed. The route is synthetic and labeled. **Exit Demo** is available on the map and in Demo & Testing, and clears replay/navigation state before returning to live mode. Live destination lookup is disabled during a demo. Normal launches always open the ordinary live driving map. Or launch a Debug build with:

```sh
xcrun simctl launch --terminate-running-process booted nl.joswigchert.roadscout --navigation-replay
```

Backend checks (run from `backend/`):

```sh
go test -race -timeout 30s ./...
go vet ./...
```

Navigation is foreground-only, ETA/timing are estimates, and speed limits stay unknown. Camera/weather/scenic/CarPlay features remain in later phases. Live NAS integration, graph coverage and physical-device road acceptance must be verified separately; see `docs/testing.md`.

## Map-first UI redesign verification · 2026-10-24

Debug and Release builds passed, all 37 Swift test methods / 51 executed cases passed, and normal plus `--navigation-replay` launches were inspected in the iPhone 17 Pro simulator. Map-first layout, drawer states, speed/limit chips, guidance strip, settings/Exit Demo controls, and reduced-transparency handling were reviewed. Physical-device, VoiceOver, Dynamic Type, reduced-motion, road and CarPlay checks remain pending; no device/road/CarPlay test is claimed.
