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
