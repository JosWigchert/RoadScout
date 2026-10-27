# Mounted-phone driving motion

## Scope and acceptance (recorded before implementation)

Owner requested GPS/speed prediction assisted by accelerometer, gyroscope and magnetometer for continuous arrow/camera movement. Optimize for a mounted phone; fall back when motion is unavailable or phone handling is detected. This is a foreground refinement of free drive/navigation, not completion of physical-device hardening.

Acceptance checks:

- Continuous 30 Hz display pose with location fixes 0.5–1 s apart; arrow and camera use the same pose.
- GPS anchors position/speed/course; gravity-compensated, north-referenced acceleration assists speed and gravity-axis gyroscope rotation assists turns. Magnetic accuracy gates north-referenced acceleration.
- Ordinary GPS corrections converge smoothly; implausible/inaccurate single fixes do not pull the display across the map. Genuine large, accurate relocations reset instead of animating through an invented journey.
- Stops do not creep; compass/device rotation alone does not spin a stopped car.
- Phone tilt/handling, sensor gaps, unavailable north reference and magnetic interference fall back to GPS speed/course prediction. Slow phone yaw cannot always be distinguished from vehicle yaw and requires mounted-device acceptance.
- Motion prediction is bounded to two seconds after the last usable location measurement, then freezes; no long-term inertial navigation claim.
- Use monotonic integration time and explicitly map CLLocation wall-clock timestamps. Reject stale/out-of-order/invalid inputs.
- Navigation, measured GPS speed, arrival and camera warnings continue consuming validated location fixes, not predicted display poses.
- Confirmed off-route movement recalculates through Go/Valhalla and automatically adopts the first returned route. Preserve preferences/objective/budget; stale requests cannot resurrect ended navigation. Do not snap the pose to the old/new route.
- Sensors/render clock stop on session end, backgrounding and permission loss; previews/replays must not open real sensors.
- Deterministic estimator/provider-lifecycle and rerouting tests, Debug full tests, Release build, synthetic simulator inspection. Mounted-iPhone stop/turn/braking/missed-turn tests and energy tuning remain separate acceptance gates.

## Implementation order

1. Injectable Core Motion provider, bounded pure estimator and display clock.
2. DrivingModel session integration and shared arrow/follow-camera presentation.
3. Deterministic motion/reroute tests and build verification.
4. README, architecture, milestones, privacy and testing results.

## Implemented design

- `CoreMotionProvider`: 50 Hz Apple device-motion fusion; true-north attitude when available, arbitrary vertical frame otherwise. Acceleration is gravity-compensated, rotated device → reference with the transposed attitude matrix, converted g → m/s² and projected onto GPS travel direction. Medium/high magnetic calibration is required for north/east acceleration; gravity-axis gyro remains usable without it. No device compass heading is directly substituted for vehicle course.
- `DrivingMotionEstimator`: pure bounded complementary predict/correct filter. GPS position accuracy weights corrections; GPS speed reanchors inertial speed at each fix. Position/heading correction offsets decay with a 0.3 s time constant. Speed/acceleration/yaw influence is bounded, low-speed jitter is held, and unusable speed/course disables unsupported prediction. Two consistent accurate fixes are required for a large relocation.
- Samples use boot-relative time; location measurement age is explicitly mapped into uptime. Location prediction expires two seconds after measurement time, including when GPS delivery is delayed. Stale motion (>150 ms) is ignored. Rapid tilt, >1.2 rad/s rotation, >2.5 m/s² vertical acceleration or a large GPS/gyro heading disagreement suppresses motion assistance for two seconds. Slow phone yaw and magnetic errors cannot always be distinguished from car motion: mounted-device tuning is still required.
- `DrivingMotionModel`: injected sensor provider, wall/monotonic clocks and display clock. A weak-target CADisplayLink requests 30 Hz (20–30 Hz frame-rate range; actual cadence is system-controlled). Session generations reject callbacks from stopped sessions. No sensors are opened by ordinary replays; the explicit synthetic preview injects its own fake sensor source.
- `DrivingMapSurface`: owns high-frequency pose observation, arrow heading compensation and driving camera state. Both use the same pose; continuous motion has no stacked easing animations, including under Reduce Motion. End-of-camera reports to the surrounding UI are throttled while following. Gesture/recenter and planning-camera state remain separate.
- Raw validated fixes continue to drive navigation, measured speed and camera warnings. Routes never constrain predicted position. Automatic first-route adoption remains in `NavigationModel`; returning to the loaded route cancels an in-flight reroute. A signal gap outside the route must not be mistaken for recovery just because hysteresis restarts.

## Verification

Deterministic tests cover constant-speed frame spacing, acceleration/braking, longitudinal projection, north crossing, stationary jitter, handling, magnetic/reference fallback, sensor dropout, two-second freeze, smooth GPS correction, relocation confirmation, delayed/invalid inputs, course/speed accuracy, dateline crossing, lifecycle/stale callbacks and separation from measured fixes/speed. Navigation tests cover first-of-multiple-route adoption, return-to-route cancellation, outside-route signal gaps, retained objective/budget/preferences and ended-session response rejection.

The Debug full test suite and Release simulator build passed. Simulator synthetic motion appearance was inspected with `--motion-preview` (1 Hz GPS, ~50 Hz synthetic motion); these are invented trajectories, not validated road geometry or real sensor measurements. See `testing.md` for final counts.

### Mounted-iPhone acceptance still required

Check position/camera cadence and lag during straight driving, acceleration/braking, slow/fast curves, roundabouts and stops; then pick up/reseat the phone and check GPS fallback. Verify magnetic interference, a short GPS loss/recovery and a deliberate missed turn with automatic adoption of the first new route. Check gestures/recenter, End/background sensor shutdown, thermal/energy impact and Reduce Motion. No physical-device, road or CarPlay tests have been performed here.
