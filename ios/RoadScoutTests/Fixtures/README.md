# Location fixtures

The canonical synthetic replay fixture is `RoadScout/Resources/free-drive.json`, bundled with the app so the same samples can be tested and replayed on the map. It covers acceleration, jitter, invalid speed, poor position accuracy and stopping. Coordinates are synthetic, not a road recording. Tests also construct timestamped fixes to cover stale/future/out-of-order samples without relying on wall-clock time.
