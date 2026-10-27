# RoadScout

iPhone driving companion built with SwiftUI and MapKit. See `RoadScout_Requirements_OpenCode.md` for the product specification.

## Open and run

Open `ios/RoadScout.xcodeproj`, select the **RoadScout** scheme and an iPhone simulator, then Run. Minimum deployment target: iOS 18. No dependencies, service credentials or project generator are needed.

For a physical iPhone, select your development team in Signing & Capabilities and use an available bundle identifier. Location permission is requested when engaging search/Use my location for nearby places, or when starting a live drive—not on launch.

The app bundle identifier is `nl.joswigchert.roadscout` (tests: `nl.joswigchert.roadscout.tests`). Automatic signing still requires registration with your selected Apple development team.

### Temporary hosted LAN testing

The Go API is currently hosted on this Mac at **`http://192.168.1.157:8080`**, listening on all interfaces and using NAS Valhalla at `http://192.168.1.111:8002`.

- Build/run **Debug** on an iPhone on the same LAN/Wi-Fi and allow RoadScout's **Local Network** permission. Debug defaults to the Mac's URL and migrates the previously saved public default; unrelated explicit overrides are preserved. Settings → Demo & Testing → Use default server selects the current build's default.
- **Release** still defaults to `https://roadscout.joswigchert.nl`, requires HTTPS and migrates the temporary LAN URL back to that public default. Its processed Info.plist contains no local HTTP exception. Build Release to return to the production configuration.
- The HTTP exception is limited to the configured Debug host/port; redirects cannot downgrade HTTPS or switch to another HTTP host. If the Mac's IP changes, update `AppConfiguration.localTestingRoutingAPIBaseURL` and the Debug-only ATS domain in `Supporting/Info.plist`, rebuild, and select Use default server.
- Restart the current prototype server from `backend/` with `ENABLE_EXPERIMENTAL_ROUTING=1 VALHALLA_BASE_URL=http://192.168.1.111:8002 LISTEN_ADDR=0.0.0.0:8080 go run .`. Omit the experimental flag for Fastest-only API behavior. The Mac must remain reachable while testing.

Verified: LAN readiness/real routing, simulator URLSession route request, Debug full tests and Release configuration tests. Physical iPhone/Wi-Fi/firewall behavior is not yet verified.

## Command-line verification

From the repository root (Xcode 27 used during development):

```sh
xcodebuild -project ios/RoadScout.xcodeproj -scheme RoadScout -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.0.1' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
xcodebuild -project ios/RoadScout.xcodeproj -scheme RoadScout -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.0.1' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO test
```

The same commands are suitable for a macOS CI runner with that simulator installed; adjust the destination for other machines.

Optional live LAN integration test (requires the hosted Go/Valhalla chain; ordinary tests skip it):

```sh
TEST_RUNNER_ROADSCOUT_LAN_SMOKE=1 xcodebuild -quiet -project ios/RoadScout.xcodeproj -scheme RoadScout -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.0.1' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO test
```

To include the opt-in prototype route test, also set `TEST_RUNNER_ROADSCOUT_EXPERIMENTAL_SMOKE=1` and run Go with `ENABLE_EXPERIMENTAL_ROUTING=1`.

## Roof Down weather · Phase 4

Directions automatically checks weather for every route alternative when **Settings → Roof Down weather → Show Roof Down weather** is enabled. Cards show Roof Down, Rain Risk (probability, mm/h and encounter time), or Forecast Unavailable. Only the selected route displays dashed rain segments and a rain-cloud marker at the worst location. Weather is planning-only; entering a drive clears weather work and overlays.

The Go API issues a 15-minute token per route, then accepts token + departure-now at `POST /v1/weather`; the phone does not resend geometry. Bounded server caches are memory-only. Open-Meteo provides 15-minute precipitation (converted from mm to mm/h) and hourly probability; their timestamps end the preceding accumulation/probability interval. Native temporal resolution varies by region; forecasts are guidance, not a dry-roof guarantee. Any missing route sample yields Forecast Unavailable. Tokens expire with **Weather expired — recalculate**.

Weather data by [Open-Meteo.com](https://open-meteo.com/), CC BY 4.0. The hosted free API has non-commercial usage terms; review terms/limits before distribution. KNMI integration awaits a server-side key. Contract, sampling and acceptance: [`docs/phase-4.md`](docs/phase-4.md), [`docs/weather-api.yaml`](docs/weather-api.yaml).

Verified 2026-10-25: Go race tests/vet, Debug simulator build/full tests, Release build, live weather for all three Utrecht–Amersfoort alternatives, and simulator planning appearance. Physical-device and road weather acceptance remain pending.

## Layout

- `ios/`: native app and deterministic unit tests.
- `backend/`: small Go routing API and deterministic adapter/server tests.
- `deploy/`: Go NAS/Traefik deployment and optional standalone Valhalla development stack.
- `docs/`: architecture, milestones, verification and data obligations.

### SwiftUI previews

The search drawer uses the native resizable sheet with compact, medium and large detents. Focusing search expands it for the keyboard; the map remains interactive. **Drawer · medium** and **Drawer · expanded** previews expose the larger layouts. Map icon controls use neutral circular system glass surfaces (solid circular fallbacks on older iOS/reduced transparency).

The search capsule and circular drive control share a 44-point height; 16-point insets and a coordinated 38-point outer sheet radius keep the nested curves consistent. The compact drawer is 76 points tall, centering the row with equal top/bottom spacing.

The planning row is **Search → Current location → Drive**: the location arrow is a separate circular button outside the search capsule.

Open `ios/RoadScout/App/ContentView.swift` and enable Xcode's Canvas. Alongside the planning previews, **Driving · simulated 50 km/h**, **Driving · landscape**, and **Driving · dark** use a fixed synthetic location/speed through the injected location provider, without requesting GPS permission. Units follow the saved app preference. Planning hides speed/limit; the steering-wheel icon starts a drive.

MapKit displays maps and searches places. The app requests routes from a small Go API; its initial provider is self-hosted Valhalla. See `docs/phase-2.md` and the OpenAPI contract in `docs/routing-api.yaml`.

### Search and place details

- Type a shop, place or address. Suggestions and resolved places use grouped rows with category icons, neutral titles and separated address/distance subtitles.
- A one-shot planning location enables **Nearest first** sorting and current-origin distances without entering driving mode. **Best match** preserves Apple's result order. Without a location, search is biased to the viewed map and distances are omitted; saved distances are never reused. Displayed distances are straight-line estimates, in the selected unit system.
- Tap a result to replace the drawer with **Directions** and calculate the complete RoadScout/Valhalla route from your planning position. The selected route is blue, available alternatives are muted, and the whole route is fitted above the medium drawer. Route cards show distance, estimated travel time/arrival and a Drive action. Loading/failure/retry states remain visible; no line or ETA is fabricated when the server is unavailable.
- Tap the **From** row to search for a different starting point; **My location** restores the physical-location origin. Tap **To** to change the destination. These searches are independent, so editing an origin preserves the selected destination and original search results. Release offers Fastest; Debug also offers the opt-in experimental objectives below. Dynamic remains future work.
- **Drive** uses a fresh physical GPS fix. A selected preview/alternative is preserved when its start is within 50 m; moving farther or using a custom planning origin triggers recalculation from reality. The requested objective/detour budget is retained for recalculation/rerouting. Close returns to search results.
- `ios/RoadScout/App/PlaceSearchPreviewFixtures.swift` provides full search/list/detail Canvas previews with synthetic places and isolated recents. Debug simulator arguments `--search-preview` and `--destination-preview` show the same screens with stubbed search/location/routing; Release ignores these flags. The component previews live in `PlaceSearchViews.swift`.

For full-route planning previews use Debug arguments `--route-preview`, `--custom-origin-preview`, and `--origin-search-preview`. Their geometry is deliberately synthetic, not verified road geometry. The same route/origin screens are available as Canvas previews in `PlaceSearchPreviewFixtures.swift`.

### Route styles come from the server

The route-style list, their titles, whether they are experimental and their extra-time budgets are advertised by the Go API at `/v1/capabilities`. The app fetches this on launch and whenever the API URL changes. Adding or renaming a route style is therefore a **Go-only change** — no app update needed. If the server is unreachable, the app falls back to Fastest only.

Turn experimental styles on or off in **Settings → Route styles → Include experimental routing** (off by default). With it on and the server advertising them, Directions shows a style picker and a per-style budget menu. The current local Go server has experiments enabled; NAS deployment must set `ENABLE_EXPERIMENTAL_ROUTING=1`.

Decoding is deliberately lenient: missing or newer experimental fields never fail a working route.

### Experimental Scenic / More Corners

The owner brought this Phase 6 **prototype** forward; earlier device/phase acceptance remains open. With experimental routing enabled, select a destination and tap the style label in Directions to choose **Fastest**, **Scenic** or **More Corners**. Budgets come from the server (currently **15%, 30%, 50%, 85% or 100%**).

- Both objectives use the same Valhalla `auto` car router and a pool of at most six ordinary/motorway-deemphasized candidates. No second engine, graph import, motorcycle access or restriction bypass is used.
- Scenic ranks the share of eligible paved, lower-road-density roads: a countryside proxy, not measured beauty. More Corners ranks qualifying bend density after excluding junction turns, roundabouts, U-turn-like geometry, high-density/residential/service roads and unpaved segments. Candidates with more than 100 m of unpaved geometry cannot be promoted.
- A valid improvement must fit the time budget. Otherwise the UI explicitly shows Fastest with a no-improvement/metadata message. This is limited-pool reranking, **not a globally optimized winding/scenic router**.
- Route alternatives use supplied road names, e.g. **Via N237** or **Via A27 · A1**. If road metadata is absent, alternatives are numbered correctly starting at **Alternative 1**.
- Live Limburg checks: Sittard → Vaals improved from a fastest-available baseline of 31.2 min / 1 qualifying bend to 39.7 min / 17 qualifying bends (+27.5% time). Valkenburg → Epen's Fastest already scored 34 qualifying bends and 99.6% eligible country roads, so the prototype honestly retained it. These are algorithm estimates, not field assessments.
- `--live-scenic-preview` / `--live-corners-preview` and their Canvas variants use a synthetic Utrecht starting fix with **real LAN routing** to Amersfoort. They require the local Go server and are distinct from offline synthetic geometry previews.

See `docs/phase-6-prototype.md` for the scoring/verification limits. Release's profile picker remains Fastest-only.

## Free drive (Phase 1)

Driving has its own animated map mode: the planning sheet/search dismiss, the map moves into closer tilted heading-follow, and equal-size circular speed/limit instruments appear. The speed circle contains only the number in your selected km/h or mph setting. A single bottom card contains maneuver guidance, estimated arrival/remaining time/distance, **End**, sound and route information. End stops the session/GPS and returns to planning. Recenter appears just above the card's top-right edge only after panning away from follow. There is no separate large Stop button or GPS-speed-unavailable banner; unknown speed remains a dash.

The driving position marker is a white arrow with a dark outline, without a blue puck. Display heading now uses a responsive **0.3-second** circular filter with 0.15-second source-heading and 0.35-second camera easing. Actual map rotation is compensated immediately rather than adding another arrow animation, avoiding the earlier compounded multi-second lag. Reduced Motion disables interpolation. Navigation's GPS/course inputs are unchanged. A standalone arrow Canvas preview is in `Features/Driving/DrivingPositionArrow.swift`.

Free drive has a compact bottom card with End. Route loading/errors/retry, ready/resume and arrival states share the navigation card. The ellipsis opens full route attribution and estimate information. `ContentView.swift` includes full-screen navigation, unknown-speed, recenter and landscape Canvas previews; `DrivingDashboard.swift` also has a free-drive component preview. Debug arguments `--driving-dashboard-preview --missing-speed --panned` show a fixed synthetic navigation screen without GPS permission or a routing request.

The overspeed design uses a red ring and an exclamation badge when valid measured speed exceeds a verified limit. **No live posted-limit source is connected yet**, so the app currently shows an unknown limit and never invents an overspeed warning. `Features/Driving/DrivingInstruments.swift` includes below-limit, synthetic overspeed, mph and unavailable previews. The driving and limit circles share a 94-point diameter and Dynamic Type scaling.

- Tap the **steering-wheel button**, then allow location access to display your position and GPS speed. **End** stops location/heading updates and clears the reading.
- Drag/zoom/rotate the map to explore. Tap the location arrow to recenter and resume heading-follow mode.
- Open **Settings** to choose km/h or mph. Units persist locally and initially follow the device locale.
- To try it without GPS, open **Settings → Demo & Testing → Start free-drive demo**. The labeled 15-second replay includes acceleration, GPS errors and stopping. Tap **End** in the bottom card to exit the demo and restore live mode. Demos do not persist across app launches.
- Unknown speed shows **—**, never an invented zero. Speed limit remains explicitly unknown.
- Appearance follows the system. Active sessions keep the screen awake; manual locking/backgrounding stops the session. Restart explicitly on return. Background navigation is deferred to Phase 5.

For an automated Debug simulator preview, add `--replay` to the scheme's launch arguments, or use (Release builds ignore replay launch flags):

```sh
xcrun simctl launch --terminate-running-process booted nl.joswigchert.roadscout --replay
```

## Verification status

Latest local Go smoke check (2026-10-24): `/healthz` and `/readyz` pass on `127.0.0.1:8080`, using NAS Valhalla at `http://192.168.1.111:8002` (reported version 3.5.1). The real Utrecht → Amersfoort sample returns three routes: approximately **28.06 km / 23.9 min**, **27.82 km / 26.5 min**, and **39.72 km / 30.9 min**, with no warnings. This supersedes the earlier connection failure. Public HTTPS and physical navigation/road acceptance remain pending.

Current verification: **74 Debug Swift test methods / 97 executed cases passed**, including real Fastest and experimental LAN URLSession requests; **72 Release methods / 95 executed cases passed**. Go race tests and vet passed at prototype verification. Real local Go → NAS Valhalla routing, metadata and prototype comparisons are verified; public HTTPS/Docker deployment, full graph coverage and physical-device acceptance remain pending. Phase 2's earlier 37-method/51-case result is historical. Deployment instructions: `backend/README.md`; prototype results: `docs/phase-6-prototype.md`.

RoadScout rename verified on 2026-10-23: the renamed project builds, all 21 test methods pass (29 executed cases), and `com.roadscout.RoadScout` installs and launches in the simulator with synthetic replay.

Phase 0 is verified. Phase 1 is implemented and simulator-verified: build succeeds, 21 test methods pass (29 executed cases including parameterized inputs), and light/replay plus dark/idle screens were inspected. **Phase 1's real-device acceptance is still pending.** No physical-device, road or CarPlay testing has been performed. See `docs/testing.md` for the device checklist and `docs/milestones.md` for the roadmap.

## Navigation (Phase 2)

1. Deploy Go on your NAS using `backend/README.md`. Defaults: HTTP **:8080**, upstream **http://Valhalla:8002**. Traefik supplies the app-facing HTTPS hostname. Direct LAN testing uses **http://192.168.1.111:8080**.
2. Release defaults to **https://roadscout.joswigchert.nl**; the temporary Debug LAN default is **http://192.168.1.157:8080**. Set toll/motorway preferences in Settings if desired. An endpoint override and reset-to-default action live under **Settings → Demo & Testing**. Unrelated explicit overrides are preserved; the known public/LAN defaults migrate according to the build configuration.
3. In planning mode, search a place/address and select a result. Directions calculates and fits the full route on the map. Edit From/To if needed and review route estimates/alternatives; tap **Drive**. Allow location if needed. Guidance starts after a fresh driving fix and a successful RoadScout route response.
4. Speed stays visible. Guidance is spoken unless muted. Rerouting requires sustained off-route evidence and uses cooldown/backoff. If Go/Valhalla is unreachable, the loaded route stays in memory; no new route can be calculated.
5. **End** on the bottom card ends navigation and GPS and returns to planning. Backgrounding stops GPS and pauses loaded guidance; restart through planning with a fresh physical fix.

To try navigation without a server, use **Settings → Demo & Testing → Start navigation demo**. Replay and navigation start automatically; no GPS permission or server is needed. The route is synthetic and labeled. **End** on the driving card clears replay/navigation state and returns to live planning. Live destination lookup is disabled during a demo. Normal launches always open the ordinary live driving map. Or launch a Debug build with:

```sh
xcrun simctl launch --terminate-running-process booted nl.joswigchert.roadscout --navigation-replay
```

Backend checks (run from `backend/`):

```sh
go test -race -timeout 30s ./...
go vet ./...
```

Navigation is foreground-only, ETA/timing are estimates, and speed limits stay unknown. Weather/scenic/CarPlay features remain in later phases. Live NAS integration, graph coverage and physical-device road acceptance must be verified separately; see `docs/testing.md`.

## Cameras (Phase 3, Netherlands)

Camera data comes **only from the Go API**, through one `POST /v1/cameras` endpoint. The app does not bundle a camera dataset.

- Go keeps a persistent snapshot in `CAMERA_DATA_DIR` (Docker: `/data/cameras`). A background task in the same container checks OpenStreetMap every six hours, reconciles by stable OSM IDs, writes atomically and keeps the last known-good snapshot on failure. Image updates do not erase the bind-mounted folder.
- The snapshot currently contains **936 mapped cameras** and **76 average-speed zones** (65 with verified connected geometry, 11 incomplete). Coverage is the Netherlands and is explicitly incomplete; mapped records do not confirm active enforcement.
- The app shows a camera dot with a white ring and a short **direction beam** for known enforcement travel direction. Nearby cameras are grouped into **counted clusters** when the map is dense; tapping a cluster zooms in, and tapping an individual camera opens a card with its mapped limit and heading.
- A warning strip appears above the driving dashboard. Average-speed zones use purple dashed geometry and start/end markers; average-speed calculation is deferred.
- Settings → Cameras controls visibility, audio and warning distance, and shows coverage, last check/change/source timestamps, attribution and stale status.
- Route preview and navigation request cameras for the route corridor; free drive requests a bounded area around the current position. The app caches fetched query areas for network gaps only; it does not claim uncached offline coverage.

Deploy the mount (example Unraid path) with `CAMERA_DATA_HOST_DIR=/mnt/user/appdata/roadscout/cameras`. The host folder must be writable by UID/GID **10001**. See `backend/README.md` and `docs/cameras-api.yaml`.

## Map-first UI redesign verification · 2026-10-24

Debug and Release builds passed, all 37 Swift test methods / 51 executed cases passed, and normal plus `--navigation-replay` launches were inspected in the iPhone 17 Pro simulator. Map-first layout, drawer states, speed/limit chips, guidance strip, settings/Exit Demo controls, and reduced-transparency handling were reviewed. Physical-device, VoiceOver, Dynamic Type, reduced-motion, road and CarPlay checks remain pending; no device/road/CarPlay test is claimed.

## App icon

The app icon is an **Icon Composer** document at `ios/RoadScout/Resources/AppIcon.icon/`. It uses two SVG layers over an automatic blue gradient:

- `Assets/road.svg` — a winding road ribbon with a dashed centre line (glass + translucency).
- `Assets/arrow.svg` — the white navigation arrow with a neutral shadow.

Edit it visually by opening `AppIcon.icon` in **Icon Composer** (Xcode 26). The document is wired through `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`.

A 1024×1024 PNG fallback lives in `Assets.xcassets/AppIcon.appiconset/` for iOS 18–25. Regenerate it after editing the icon:

```sh
xcrun ictool ios/RoadScout/Resources/AppIcon.icon --export-image \
  --output-file /tmp/AppIcon-1024.png --platform iOS --rendition Default \
  --width 1024 --height 1024 --scale 1
```

Then replace `AppIcon-1024.png` in the appiconset. No text is used in the icon; SVG text must be converted to paths.

Route relevance is deliberately conservative. Cameras near the selected route are shown, but a spoken warning requires matching OSM way identity and compatible enforcement direction; otherwise they are marked nearby/uncertain. A live Utrecht–Amersfoort check produced no confirmed records because the available OSM way/direction evidence did not align, so the app would display them without a confident camera announcement.
