# RoadScout — Product Requirements and Implementation Plan

**Version:** 2.0  
**Status:** Approved direction, implementation specification  
**Target:** iPhone first; CarPlay once entitled; worldwide support  
**Audience:** OpenCode coding agent and project maintainer  
**Last updated:** 2026-10-22

**Owner-approved amendment · 2026-10-23:** introduce the small engine-independent Go routing API in Phase 2. Its initial adapter uses the existing Valhalla Europe deployment. This supersedes references below that defer all custom Go work to Phase 8 or describe the MVP as directly calling Valhalla. Accounts, community databases and later-phase features remain deferred. See `docs/phase-2.md` and `docs/routing-api.yaml`.

**Owner-requested prototype priority · 2026-10-24:** bring an experimental Scenic/More Corners investigation forward alongside the unfinished earlier-phase acceptance gates. This is a bounded Valhalla candidate-ranking prototype, not completion of Phase 6 or permission to claim globally optimized scenic/winding routes. Keep production Fastest unchanged; see `docs/phase-6-prototype.md` for the plan, limits and acceptance checks. Section 2 remains binding.

## 1. Product vision

Build a reliable, attractive navigation and driving companion app that can eventually replace Flitsmeister for its owner and later be distributed publicly. Its differentiators are:

1. **Always visible GPS speed and speed camera alerts**, whether or not a destination is set.
2. **Roof Down Mode:** weather-based advice for convertible drivers using precipitation forecasts evaluated *where and when* the car will be along the route.
3. **Scenic / Most Corners routing:** enjoyable winding-road routes, not merely the shortest or fastest routes.
4. A clean iPhone driving interface, with eventual Apple CarPlay integration.

Essential driving/navigation features should remain usable for free. Favor free Apple SDKs, open-source code and appropriately licensed open data. No mandatory paid routing or weather API subscriptions. Do not sacrifice basic reliability in pursuit of additional features.

## 2. Decisions already made (do not override)

- **iOS:** Swift, SwiftUI, Apple MapKit for map **display only**.
- **All route computation:** Valhalla using OpenStreetMap road network data. **Do not use `MKDirections` or Apple Maps routing** as an alternate route engine.
- **Map display and routing are separate:** decode Valhalla route geometry into a MapKit polyline. Map data differences may cause alignment errors; test them.
- **Navigation engine:** implemented in Swift, consuming Valhalla guidance and geometry.
- **MVP backend (owner amendment, 2026-10-23):** a small Go `net/http` routing API in Phase 2 normalizes the configured engine into a versioned RoadScout contract. Valhalla remains the initial and only implemented route engine. No user accounts or central community database. Swift consumes RoadScout geometry/guidance; engine-specific JSON stays in Go.
- **Future services:** Go (`net/http`), self-hosted through Docker on Unraid, exposed over HTTPS through existing Traefik. Postgres/PostGIS only when justified.
- **Weather:** Apple WeatherKit as the initial worldwide provider if developer entitlement/account and actual usage terms permit; weather provider interface must allow replacement. Self-hosted Open-Meteo and regional radar sources (KNMI, etc.) are later options.
- **Worldwide product:** no Netherlands-only assumptions in UI, units, routing or weather. Initially optimize/import camera datasets for the Netherlands, and make country coverage explicitly visible to the user.
- **CarPlay:** planned from the start architecturally, but not a blocker for iPhone MVP. Native CarPlay navigation requires Apple's relevant entitlement and platform compliance.
- **No paid third-party SDK dependency.** Apple's included system SDKs are allowed. Observe OSM, weather-provider and dataset licenses and attributions.

## 3. MVP definition (first useful release)

The iPhone app is usable on real drives and contains:

### 3.1 Driving map / free drive

- MapKit map with live position, heading and follow-camera behavior.
- Large, always visible **GPS speedometer** in km/h or mph; use Core Location speed and reject invalid/low-confidence readings. Smooth jitter without lagging dangerously. Speed must be visible both in free drive and while navigating.
- Speed limit shown only when backed by usable map data; unknown must show as unknown. Never confuse measured speed with posted speed limit.
- Start/stop driving session; navigation remains available without a destination.
- Manual map gestures, recenter control, day/night appearance, readable contrast and large touch targets.

### 3.2 Valhalla route navigation

- Destination search (Apple `MKLocalSearch` may be used for **place search**, but **not routing**).
- Call the RoadScout Go API over HTTPS through Traefik for route calculation. Go calls the existing Valhalla service over the private Docker network; include shape, duration, maneuvers and alternatives when available.
- Show routes, travel time, remaining distance, next maneuver, voice guidance and arrival ETA.
- GPS-to-route matching, maneuver progress, off-route detection and rerouting with rate limiting/hysteresis.
- Fastest driving route as the first routing profile. Support legal constraints, vehicle access rules, tolls/highway preferences where the engine supports them.
- Handle network loss: keep currently loaded route and locally cached camera data; show that new routes cannot be calculated while Valhalla is unreachable. **Do not claim offline routing** unless it is implemented.

### 3.3 Speed camera awareness

- Display fixed speed camera positions on the map and warn when approaching relevant cameras, even in free-drive mode.
- Start with reproducible, legally reusable OpenStreetMap imports (`highway=speed_camera`, relevant enforcement relations) plus explicitly sourced official data where permitted.
- Store data locally for offline warnings, with import timestamps, source attribution and region coverage.
- Camera types: fixed, average-speed zone (start/end), relocatable/flex where a verifiable feed exists, mobile reported (later).
- Prioritize cameras on the driver's road and travel direction; calculate along-route distance during navigation rather than only crow-flight distance. In free-drive, filter by heading and reasonable road proximity, acknowledge ambiguity at parallel roads.
- Configurable warning distances and audio. Debounce alerts to avoid repeats; never assume a camera is active when its status is uncertain.
- Show last data update and region coverage. Never promise a complete list of worldwide cameras.

### 3.4 Roof Down Mode (required in MVP)

- Optional toggle and a prominent route-level recommendation: **Roof Down**, **Rain Risk**, **Roof Up**, or **Forecast Unavailable**.
- Sample a calculated Valhalla route at spatial intervals and associate each point with estimated time of passage. Initial travel-time distribution can be approximate, but document the method and update using real route progress.
- Fetch the relevant forecast for each route sample; use future precipitation at *predicted arrival time*, not just current weather or weather at the destination.
- Show on-route locations/segments with rain risk, estimated encounter time, confidence/uncertainty and last forecast update.
- Allow adjustable precipitation-intensity and probability thresholds and optional audio warning prior to likely rain.
- Weather service errors must never block navigation. Do not describe forecasts as certainties or a mechanical guarantee that the roof can remain open.
- Cache forecasts responsibly to reduce data usage, respecting provider terms. Do not continuously call WeatherKit for every GPS update.
- WeatherKit's worldwide hourly forecasts are a starting point; minute-by-minute precipitation coverage is limited by geography. Clearly communicate regional precision differences.

### 3.5 Reliability and safety

- No UI freezes from networking, routing, weather evaluation or camera imports.
- GPS permission and background location modes only as necessary, with clear user explanations; verify physical-device behavior while locked and while another app is active.
- Audio navigation and warnings must handle interruptions and coexist with other car audio as permitted by iOS.
- Driving UI must be glanceable. Never require complex interactions while moving.
- No tracking/analytics SDK by default; minimize transmitted personal location information.
- Accessibility: VoiceOver labels, Dynamic Type where practical, contrast and localization-ready strings.

## 4. MVP explicitly excludes

- Native CarPlay UI before entitlement approval.
- User accounts, subscriptions, billing or advertisements.
- Public crowdsourced mobile camera reports and peer confirmation until an authorized source/backend exists.
- Claimed live traffic accuracy without a licensed/working traffic data source.
- Genuine scenic/most-corners optimization until its Valhalla costing implementation is designed and measured.
- Offline route calculation; download of entire OSM map datasets onto the phone.
- A production Go API or database simply for project structure.

## 5. Next release: Scenic and Most Corners (highest priority after MVP)

**Scenic and Most Corners must both use Valhalla, not Apple routing.** These are meaningful product features, not just labels for MapKit alternatives.

- **Scenic:** favor enjoyable countryside/landscape roads when supported by quality road metadata; allow preferences such as avoiding motorways, drive time and surface quality.
- **Most Corners:** use curvature and bend density per distance, not intersection count, roundabouts, unnecessary weaving through neighborhoods or repetitive U-turns.
- Evaluate road class, legal access, surface, length, bend radius/angle, traffic safety and forecast effects where available.
- Set configurable maximum extra drive time versus Fastest (example: 15%, 30%, 50%); ensure routes are useful and legal.
- Potential implementation: preprocess OSM road edges with curve scores; use Valhalla's configurable costing or a maintained customization/fork if necessary. **Do not assume stock Valhalla has a built-in Most Corners parameter.** Prototype, profile and document any engine changes.
- Offer route previews explaining extra time/distance and approximate winding-road score.
- Add circular scenic trips (start/finish near current position, 30/60/120 minutes) only after point-to-point winding route scoring works.

## 6. Later releases

### 6.1 CarPlay

- Apply for Apple's CarPlay navigation entitlement early. Build UI only using approved templates/APIs, sharing the underlying navigation, alerts and weather services with the phone.
- Show speed, upcoming maneuver, route, relevant camera warnings and restrained Roof Down warnings subject to CarPlay UI guidelines.
- Validate on a real CarPlay head unit or permitted simulator/testing setup, including reconnections and navigation audio.
- No assumption that an ordinary iPhone build can show arbitrary CarPlay UI without Apple's entitlement.

### 6.2 Go backend on Unraid + Traefik

- Start when shared live reports, server-side weather access or multi-user sync becomes necessary.
- Go standard `net/http` or similarly lean framework; Docker Compose; Traefik reverse proxy for public HTTPS; internal-only Valhalla/Open-Meteo networks.
- Versioned API (`/v1/...`), health checks, metrics, logs, rate limits, abuse protection, schema validation and secret management.
- Store camera/report data in PostgreSQL/PostGIS once persistence and geo querying justify it; use migrations and explicit data retention.
- Keep Valhalla a distinct service. Go can proxy/coordinate services later; it must not become required for core route guidance unless needed.
- API calls should use scoped access controls; don't ship secret third-party provider tokens inside the iOS app.

### 6.3 Live reports and community

- Driver reports for mobile cameras, accidents, roadworks, objects on roads, and confirmations/dismissals.
- Timestamp, location, direction, confidence, expiry, anti-spam measures and privacy protections.
- No dependency on undocumented Flitsmeister private endpoints, bypassing access controls, or unlicensed redistribution.
- Source licensing and geographic laws around speed camera alert functionality require review per country.

### 6.4 Advanced weather

- Self-hosted Open-Meteo forecasting service, with data/source license verification and coverage monitoring.
- Optional regional radar nowcasts (e.g. KNMI in its valid coverage), compare models, confidence scoring and weather-aware route comparison.
- Best departure time and alternative route that avoids predicted rainfall if the detour is worthwhile.
- Keep provider implementations behind an interface so WeatherKit, Open-Meteo and regional sources can be swapped independently.

### 6.5 Other possible features

- Average speed zone progress and estimated average speed.
- Custom audio profiles and speed-limit warnings where speed limit data is reliable.
- Parking reminder, trip history stored locally with opt-in sync, vehicle profiles and scenic loop sharing.
- Optional premium advanced forecasts later, but never make basic speed display/navigation/camera warnings dependent on a subscription.

## 7. Architectural boundaries and interfaces

Suggested modules and responsibilities:

```text
RoadScout/
  ios/
    RoadScoutApp/
      App/
      Features/Driving/
      Features/Navigation/
      Features/Cameras/
      Features/RoofDown/
      Features/Settings/
      Infrastructure/Location/
      Infrastructure/Routing/
      Infrastructure/Weather/
      Infrastructure/Persistence/
      Infrastructure/Audio/
    RoadScoutTests/
  routing/
    valhalla/                  # Docker + config + OSM import instructions
  backend/                     # Added in future phase, Go
  deploy/
    compose.yaml
  docs/
    architecture.md
    milestones.md
    data-sources.md
    privacy-and-licenses.md
  README.md
```

Define small Swift protocols so logic is unit-testable:

- `LocationProviding`: current fix, heading, speed, accuracy, mock GPS replay.
- `RoutingProviding`: create route, alternatives and reroute through the RoadScout API; Go initially implements the Valhalla adapter only.
- `NavigationTracking`: progress and maneuver state from route + GPS.
- `CameraProviding`: spatial queries, attribution/coverage and local cache.
- `CameraAlertEvaluating`: route matching, direction, distance, suppression.
- `WeatherProviding`: time/location forecasts with coverage and uncertainty.
- `RouteWeatherAnalyzing`: sampled route + ETA + forecasts -> recommendation and risk segments.
- `AudioAnnouncing`: turn and camera/weather warnings, priority and rate limiting.

Use versioned, explicit models for route geometry, maneuvers, cameras, weather samples, estimates and errors. Keep views thin; do not embed navigation/weather computations in SwiftUI views. Favor Swift concurrency and dependency injection over global singletons.

## 8. Project execution phases and acceptance criteria

### Phase 0: Repository and build foundation

Deliver: Xcode project, clear modules, automated tests, README, architecture notes, basic CI build/test command, sample data and GPS replay fixtures.

**Done when:** project builds on available Xcode; tests execute; permissions are described and app launches without server credentials.

### Phase 1: Map + GPS + free drive

Deliver: map display, user location/heading, large GPS speed, units, follow/recenter, session control, mock location replay.

**Done when:** speed updates smoothly on real device, unknown speed is handled correctly, and drive mode works with no destination.

### Phase 2: Valhalla service + navigation

Deliver: versioned engine-independent routing contract, Go API on port 8080 with Valhalla adapter targeting `http://Valhalla:8002`, Docker/Traefik deployment using the owner's NAS at `192.168.1.111`, Swift API client, destination lookup, route preview, tracking, voice prompts and rerouting. Reuse the owner's Europe graph. See `docs/phase-2.md` for the acceptance plan.

**Done when:** a route from origin to destination can be calculated, displayed, followed and recalculated using Valhalla only. Loss of routing service is represented honestly.

### Phase 3: Camera warning MVP

Deliver: static/imported OSM camera datasets, source and region metadata, local database, map markers, ahead-of-car matching, configurable warnings and audio, average speed zones only if properly modeled.

**Done when:** seeded/replayed GPS routes raise warnings for a camera ahead but not for one behind or on an unrelated parallel road; duplicate alerts are suppressed and stale data is labeled.

### Phase 4: Roof Down Mode MVP

Deliver: global WeatherKit provider (subject to entitlements), weather-provider abstraction, Valhalla route sampling, ETA prediction, weather fetch/cache, roof recommendation and route rain segments.

**Done when:** simulated routes with storms before/after passing times produce sensible different outcomes; missing weather never disrupts navigation; tests assert freshness and quota-conscious requests.

### Phase 5: Real-world MVP hardening

Deliver: background/locked behavior, battery/network resilience, guidance prioritization, crash handling, real driving field test checklist, privacy/attribution UI, clear coverage messaging and accessibility.

**Done when:** repeated physical-device drives work without missed essential warnings or persistent navigation failure, and documented limitations are visible.

### Phase 6: Scenic / Most Corners via Valhalla

Deliver: prototype custom winding-road scoring/costing with objective comparisons against fastest route, legal constraints and detour budget. Add scenic mode and route comparison first, loop routes afterwards.

**Done when:** tested routes demonstrably contain more meaningful curves without disproportionate detours or unsafe road selection. Tests include urban false positives and highway alternatives.

### Phase 7: CarPlay

Deliver: CarPlay navigation interface conditional on Apple entitlement, real-world testing and shared engine integration.

**Done when:** entitlement is approved and the CarPlay navigation experience complies with Apple's requirements and survives disconnect/reconnect.

### Phase 8: Shared Go services, live data and advanced weather

Deliver: authenticated public Go service through Traefik, report ingestion/moderation, source ingestion, PostGIS where needed, optional self-hosted Open-Meteo and regional nowcasting.

**Done when:** multiple installations can retrieve authorized live reports safely, services have monitoring/backups, and backend downtime does not disable already loaded navigation and local fixed-camera alerts.

## 9. Tests to implement throughout

- Navigation: bad route shapes, route alternatives, GPS jitter, tunnels, off-route/reroute thresholds, stale requests, concurrency and service timeout.
- Speed: negative/invalid speed, poor GPS accuracy, m/s to km/h/mph conversion, smoothing, stopped vehicle.
- Camera alerts: wrong travel direction, opposite carriageway, parallel road, no destination, duplicate events, different camera types, database age.
- Weather: rain at departure/middle/destination, shower arriving just after vehicle passes, route ETA shifts, multiple weather sources disagree, forecast unavailable, timezone handling, data freshness.
- Scenic: short routes, city grids, U-turn loops, residential streets, detour caps, access restrictions, low-quality surfaces and curvature scoring.
- Security and operations: malformed APIs, missing credentials, rate limits, no secrets in git, routing service outage.

Prefer deterministic unit tests with fixture routes, camera coordinates, sample forecast responses and replayable GPX tracks over tests that depend on live provider uptime.

## 10. Data, privacy, licensing and operational constraints

- OpenStreetMap uses ODbL and requires attribution; review obligations for derived databases before public release.
- Individual speed-camera source data may have different licenses. Record source, license, last-updated time and geographic coverage per dataset.
- Apple MapKit and WeatherKit are Apple services, not open-source. Their usage remains subject to Apple developer terms and available quotas. Native WeatherKit access and quotas should be verified in the actual developer account.
- Public Overpass/OSM services are not production sync backends for a consumer fleet. Use appropriate scheduled imports and compliant infrastructure.
- Self-hosted Valhalla requires OSM graph downloads, resources and route service uptime. Worldwide routing needs a deliberate region-by-region graph and capacity plan; the MVP can deploy a small Netherlands region first without claiming worldwide routing is operational yet.
- Location is sensitive: retain only what's needed, default to local route/history, and publish an accurate privacy policy before distribution.
- Alerting features can be subject to country-specific restrictions; don't assume speed camera alerts are legal in every country.
- A free code stack does not eliminate Apple Developer Program membership, home-server electricity, storage, networking, weather data licensing or possible hosting expenses.

## 11. Instructions to OpenCode

1. Read this document and treat **Section 2** as binding decisions. Do not substitute `MKDirections`, Mapbox or paid routing services.
2. Implement **one phase at a time** in the order specified. Phase 0 and Phase 1 first; do not scaffold fake implementations of all later features.
3. Before each phase, produce a concise implementation plan and identify concrete acceptance tests.
4. Keep the app compiling at each stage; run relevant tests and report the command and result. Never claim physical CarPlay or real-road testing without performing it.
5. Prefer simple, maintainable Swift with minimal comments; use small modules/protocols and explicit types.
6. Keep routing, guidance, cameras and weather independently testable using mock providers and fixtures.
7. Document any third-party dependency, license, service URL, secret requirement and data source.
8. After each phase, update README, `docs/milestones.md` and test coverage notes; identify remaining blockers without pretending unfinished features work.
9. If a product requirement cannot be met with the selected free technology, document the constraint and propose a compatible fallback rather than silently substituting a paid product.
10. Do not introduce a custom Go backend until Phase 8 unless the owner explicitly changes this plan.

### Initial task to paste into OpenCode

> Read `RoadScout_Requirements_OpenCode.md` in full. Treat it as the requirements specification. Implement Phase 0 and Phase 1 only: create a real SwiftUI iOS Xcode project, MapKit driving view, Core Location GPS speedometer, free-drive mode, mock GPS provider, unit tests, and documentation. Use Apple MapKit only for map rendering and Valhalla exclusively for all future routing. Do not implement Apple MKDirections routing, a Go backend, paid SDKs or placeholder functionality. Build and test what the environment permits and report any device-only verification steps.
