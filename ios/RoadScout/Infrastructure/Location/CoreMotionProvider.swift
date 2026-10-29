import CoreMotion
import Foundation

@MainActor protocol DrivingMotionProviding: AnyObject {
    var onSample: ((DrivingMotionSample) -> Void)? { get set }
    func start()
    func stop()
}

/// North reference is supplied by Apple's gyro/accelerometer/magnetometer fusion.
/// If that reference or magnetic calibration is unavailable, only gravity-axis gyro is used.
@MainActor final class CoreMotionProvider: DrivingMotionProviding {
    var onSample: ((DrivingMotionSample) -> Void)?
    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "RoadScout.device-motion"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
        return queue
    }()
    private var generation = UUID()

    func start() {
        stop()
        guard manager.isDeviceMotionAvailable else { return }
        let frames = CMMotionManager.availableAttitudeReferenceFrames()
        let northReferenced = frames.contains(.xTrueNorthZVertical)
        let frame: CMAttitudeReferenceFrame = northReferenced ? .xTrueNorthZVertical : .xArbitraryZVertical
        manager.deviceMotionUpdateInterval = 1.0 / 50
        manager.showsDeviceMovementDisplay = false
        let token = generation
        manager.startDeviceMotionUpdates(using: frame, to: queue,
            withHandler: Self.makeDeviceMotionHandler(northReferenced: northReferenced) { [weak self] sample in
                guard let self, self.generation == token else { return }
                self.onSample?(sample)
            })
    }

    /// Core Motion's Objective-C handler is not annotated Sendable and runs on
    /// the supplied OperationQueue. A closure created directly in start() inherits
    /// MainActor isolation under Swift 6 and traps on the first physical-device callback.
    /// Construct it nonisolated, explicitly Sendable, and cross actors only with values.
    nonisolated static func makeDeviceMotionHandler(northReferenced: Bool,
        deliver: @escaping @MainActor @Sendable (DrivingMotionSample) -> Void) -> CMDeviceMotionHandler {
        { @Sendable motion, _ in
            guard let motion else { return }
            let r = motion.attitude.rotationMatrix
            let a = motion.userAcceleration
            // CMAttitude maps reference -> device; transpose maps device -> reference.
            // North-reference axes are X north, Y west, Z up. Acceleration is in g.
            let magneticOK = motion.magneticField.accuracy == .medium || motion.magneticField.accuracy == .high
            let acceleration = DrivingMotionTransform.northEast(x: a.x, y: a.y, z: a.z,
                referenceToDevice: r, reliableNorth: northReferenced && magneticOK)
            let sample = DrivingMotionSample(timestamp: motion.timestamp,
                accelerationNorth: acceleration.north,
                accelerationEast: acceleration.east,
                clockwiseYawRate: motion.rotationRate.x * motion.gravity.x
                    + motion.rotationRate.y * motion.gravity.y + motion.rotationRate.z * motion.gravity.z,
                rotationMagnitude: sqrt(pow(motion.rotationRate.x, 2) + pow(motion.rotationRate.y, 2) + pow(motion.rotationRate.z, 2)),
                gravityX: motion.gravity.x, gravityY: motion.gravity.y, gravityZ: motion.gravity.z,
                verticalAcceleration: -(a.x * motion.gravity.x + a.y * motion.gravity.y + a.z * motion.gravity.z) * 9.80665)
            Task { @MainActor in deliver(sample) }
        }
    }

    func stop() {
        generation = UUID()
        manager.stopDeviceMotionUpdates()
        queue.cancelAllOperations()
    }

    isolated deinit { manager.stopDeviceMotionUpdates() }
}

enum DrivingMotionTransform {
    static func northEast(x: Double, y: Double, z: Double, referenceToDevice r: CMRotationMatrix,
                          reliableNorth: Bool) -> (north: Double?, east: Double?) {
        guard reliableNorth else { return (nil, nil) }
        return ((r.m11 * x + r.m21 * y + r.m31 * z) * 9.80665,
                -(r.m12 * x + r.m22 * y + r.m32 * z) * 9.80665)
    }
}
