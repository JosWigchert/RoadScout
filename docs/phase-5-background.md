# Phase 5 · Background / locked-screen driving

## Scope and acceptance (before implementation)

Owner requested background/locked navigation as the next Phase 5 slice. This does not close the remaining real-road, audio-routing, energy or accessibility gates.

- A live drive is explicitly started in the foreground. With authorized foreground location, background location capability and the system location indicator, location updates continue when locking or switching apps. Do not request Always authorization or start/relaunch tracking automatically.
- Guidance, route progress, arrival, rerouting and camera warning evaluation must consume actual location callbacks outside SwiftUI view/onChange updates. Preserve the selected route, voice priority/mute and cached camera data while backgrounded.
- Enable `location` and `audio` background modes. Audio remains real navigation/camera speech; no silent keepalive audio or background timer workaround.
- Stop accelerometer/gyro/compass and frame-driven visual prediction in the background; background guidance uses validated Core Location fixes. Restart visual motion only on foregrounding an ongoing live session, seeded from a fresh fix; never extrapolate across time spent locked.
- Permission denial/revocation, services disabled and explicit End stop the provider/background indicator, visual resources, pending guidance and camera speech. GPS/network outages retain the loaded route and recover under existing freshness/backoff rules.
- Foreground recovery preserves navigation/progress and does not recreate the location provider or start a stopped session. Demo/replay sessions still stop on backgrounding; ordinary planning location/search/weather work stops or clears.
- Settings/permission text explains continued locked/background location until End. System termination, force-quit, unavailable permissions and OS scheduling can stop service; no route/session restoration or guarantee of delivery is introduced.
- Deterministic tests: manager background flags/When In Use policy, permission/services failures, live vs demo lifecycle, motion suspension/reseeding, background progress/rerouting/arrival/camera pipeline without a view, mute/End and delayed callbacks. Debug tests, Release/device-target builds and processed Info.plist checks.
- Physical iPhone acceptance remains required: start route, lock and switch apps, verify turns/cameras/reroute/arrival/audio/music/call behavior, return without reset, End and verify indicator stops; check GPS/network loss and energy. Never claim these were performed based on fixtures/builds.

## Implementation order

1. Location/session background policy and independently injectable CLLocationManager adapter.
2. Retained callback-driven driving coordinator for navigation/cameras/audio.
3. SwiftUI scene integration and background capabilities/privacy text.
4. Deterministic tests, builds and documentation of verified vs pending checks.

## Implementation and verification · 2026-10-28

- Added location/audio background modes. Narrow injected manager tests validate When In Use-only requests, capability gating, visible indicator, no automatic location pauses, heading suspension/restart, revocation/services cleanup and no permission request while backgrounded.
- Live `DrivingModel` sessions preserve their provider and validated fixes in the background; visual motion/frame/freshness timers stop. Foreground recovery expires stale data, restarts motion and seeds only usable fixes. Demo/ended sessions never auto-restart. Explicit lifecycle/deinit cleanup stops resources.
- Added retained `DrivingSessionCoordinator` for callback-driven route starts, navigation, camera data/evaluation and speech, plus route/mute/data callbacks. No SwiftUI update is required for background progress, voice, camera warnings, rerouting or arrival. Configuration binds callbacks only on the retained coordinator, avoiding discarded-State candidates overwriting active callbacks.
- Tests deliver fixes and camera responses without creating a view; they cover first fix while locked, pending route calculation, guidance/camera progress, arrival, automatic first-reroute adoption, mute/permission loss/End and late callbacks. Motion tests verify suspended resources, stale-fix rejection and reseeding from a newer background fix without recreating the location provider.
- Full Debug tests passed before the additional route-fading UI refinement. Final focused background/route-geometry verification passed 11 tests, zero failures/skips. Release arm64 simulator and unsigned Release iPhone-target builds passed; processed plists for both contain `[location, audio]`. The universal simulator Release build timed out in x86_64 optimization; the arm64 verification used `ONLY_ACTIVE_ARCH=YES`.
- No physical-device locked/background navigation, road, Bluetooth/call routing, energy or accessibility tests were performed. These are still the acceptance gate; force-quit/system termination/OS scheduling limits remain visible in Settings.
