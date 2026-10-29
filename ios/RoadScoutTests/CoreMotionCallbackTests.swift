import CoreMotion
import Foundation
import Testing
@testable import RoadScout

// Emulate Core Motion's Objective-C callback contract: it may invoke a legacy
// non-Sendable handler on its supplied operation queue. No mutable shared state
// is accessed by this box; delivery to app state must explicitly hop to MainActor.
private final class NativeMotionCallback: @unchecked Sendable {
    let handler: CMDeviceMotionHandler
    init(_ handler: @escaping CMDeviceMotionHandler) { self.handler = handler }
}

private final class CallbackAttitude: CMAttitude {
    override var rotationMatrix: CMRotationMatrix {
        CMRotationMatrix(m11: 1, m12: 0, m13: 0, m21: 0, m22: 1, m23: 0, m31: 0, m32: 0, m33: 1)
    }
}

private final class CallbackMotion: CMDeviceMotion {
    override var timestamp: TimeInterval { 100 }
    override var attitude: CMAttitude { CallbackAttitude() }
    override var userAcceleration: CMAcceleration { CMAcceleration(x: 0.1, y: -0.2, z: 0) }
    override var gravity: CMAcceleration { CMAcceleration(x: 0, y: 0, z: -1) }
    override var rotationRate: CMRotationRate { CMRotationRate(x: 0, y: 0, z: -0.3) }
    override var magneticField: CMCalibratedMagneticField {
        CMCalibratedMagneticField(field: CMMagneticField(x: 1, y: 0, z: 0), accuracy: .high)
    }
}

@MainActor struct CoreMotionCallbackTests {
    @Test func backgroundNativeCallbackConvertsValuesAndDeliversOnMainActor() async {
        let queue = OperationQueue()
        queue.name = "RoadScout.test-native-motion"
        queue.maxConcurrentOperationCount = 1
        let sample: DrivingMotionSample = await withCheckedContinuation { continuation in
            // Construct the real production handler from MainActor, just as start() does.
            let callback = NativeMotionCallback(CoreMotionProvider.makeDeviceMotionHandler(northReferenced: true) { sample in
                MainActor.assertIsolated()
                continuation.resume(returning: sample)
            })
            queue.addOperation {
                #expect(!Thread.isMainThread)
                callback.handler(CallbackMotion(), nil)
            }
        }
        #expect(sample.timestamp == 100)
        #expect(abs((sample.accelerationNorth ?? 0) - 0.980665) < 1e-8)
        #expect(abs((sample.accelerationEast ?? 0) - 1.96133) < 1e-8)
        #expect(abs(sample.clockwiseYawRate - 0.3) < 1e-8)
    }

    @Test func backgroundNilAndErrorCallbacksAreIgnoredWithoutActorTrap() async {
        let queue = OperationQueue()
        let callback = NativeMotionCallback(CoreMotionProvider.makeDeviceMotionHandler(northReferenced: false) { _ in
            Issue.record("Nil native readings must not be delivered")
        })
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.addOperation {
                #expect(!Thread.isMainThread)
                callback.handler(nil, nil)
                callback.handler(nil, NSError(domain: "RoadScout.test", code: 1))
                continuation.resume()
            }
        }
    }
}
