#if DEBUG
import SwiftUI

/// Synthetic 1 Hz GPS + 50 Hz inertial input. No hardware location/motion is opened.
struct DrivingMotionPreview: View {
    @State private var model: DrivingModel

    init() {
        let feed = MotionPreviewFeed()
        let motion = DrivingMotionModel(makeProvider: { MotionPreviewSensors(feed: feed) })
        _model = State(initialValue: DrivingModel(makeProvider: { _ in MotionPreviewLocation(feed: feed) }, motion: motion))
    }

    var body: some View {
        ContentView(model: model)
            .task {
                model.start(source: .replay)
                // Inject synthetic sensors into the replay session, never the real provider.
                model.motion.start(live: true)
            }
            .onDisappear { model.stop() }
    }
}

@MainActor private final class MotionPreviewFeed {
    var onLocation: ((LocationEvent) -> Void)?
    var onMotion: ((DrivingMotionSample) -> Void)?
    private var task: Task<Void, Never>?

    func start() {
        stop()
        task = Task { [weak self] in
            let start = ProcessInfo.processInfo.systemUptime
            var previous = start
            var latitude = 52.09, longitude = 5.12
            var lastGPSSecond = -1
            while !Task.isCancelled {
                guard let self else { return }
                let time = ProcessInfo.processInfo.systemUptime
                let elapsed = time - start
                let dt = min(0.1, max(0, time - previous))
                previous = time
                let speed = 12 + 3 * sin(elapsed / 4)
                let heading = 45 + 25 * sin(elapsed / 6)
                let angle = heading * .pi / 180
                let acceleration = 0.75 * cos(elapsed / 4)
                let yaw = (25 * .pi / 180 / 6) * cos(elapsed / 6)
                latitude += speed * cos(angle) * dt / 111_194.9266
                longitude += speed * sin(angle) * dt / (111_194.9266 * cos(latitude * .pi / 180))
                self.onMotion?(DrivingMotionSample(timestamp: time,
                    accelerationNorth: acceleration * cos(angle) - speed * yaw * sin(angle),
                    accelerationEast: acceleration * sin(angle) + speed * yaw * cos(angle),
                    clockwiseYawRate: yaw, rotationMagnitude: abs(yaw),
                    gravityX: 0, gravityY: -1, gravityZ: 0, verticalAcceleration: 0))
                if Int(elapsed) != lastGPSSecond {
                    lastGPSSecond = Int(elapsed)
                    self.onLocation?(.fix(LocationFix(latitude: latitude, longitude: longitude,
                        speed: speed, speedAccuracy: 0.5, horizontalAccuracy: 5,
                        course: heading, timestamp: Date())))
                }
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
            }
        }
    }

    func stop() { task?.cancel(); task = nil }
    deinit { task?.cancel() }
}

@MainActor private final class MotionPreviewLocation: LocationProviding {
    var onEvent: ((LocationEvent) -> Void)?
    private let feed: MotionPreviewFeed
    init(feed: MotionPreviewFeed) { self.feed = feed }
    func start() {
        feed.onLocation = { [weak self] in self?.onEvent?($0) }
        feed.start()
    }
    func stop() { feed.stop(); feed.onLocation = nil }
}

@MainActor private final class MotionPreviewSensors: DrivingMotionProviding {
    var onSample: ((DrivingMotionSample) -> Void)?
    private let feed: MotionPreviewFeed
    init(feed: MotionPreviewFeed) { self.feed = feed }
    func start() { feed.onMotion = { [weak self] in self?.onSample?($0) } }
    func stop() { feed.onMotion = nil }
}

#Preview("Driving · synthetic sensor fusion") { DrivingMotionPreview() }
#endif
