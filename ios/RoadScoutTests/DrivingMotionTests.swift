import Foundation
import CoreMotion
import Testing
@testable import RoadScout

private let motionEpoch = Date(timeIntervalSince1970: 10_000)
private func motionFix(_ seconds: Double = 0, north: Double = 0, east: Double = 0,
                       speed: Double = 10, course: Double = 0, accuracy: Double = 5) -> LocationFix {
    LocationFix(latitude: 52 + north / 111_194.9266,
                longitude: 5 + east / (111_194.9266 * cos(52 * .pi / 180)),
                speed: speed, speedAccuracy: 0.5, horizontalAccuracy: accuracy,
                course: course, timestamp: motionEpoch.addingTimeInterval(seconds))
}
private func motionSample(_ time: Double, north: Double? = 0, east: Double? = 0,
                          yaw: Double = 0, gravityX: Double = 0, gravityZ: Double = -1,
                          rotation: Double = 0) -> DrivingMotionSample {
    DrivingMotionSample(timestamp: time, accelerationNorth: north, accelerationEast: east,
        clockwiseYawRate: yaw, rotationMagnitude: rotation,
        gravityX: gravityX, gravityY: 0, gravityZ: gravityZ, verticalAcceleration: 0)
}
// Reference harness keeps Swift Testing's expression-capture macros from copying
// a value-type receiver before a mutating estimator call.
private final class MotionEstimatorHarness {
    private var value = DrivingMotionEstimator()
    @discardableResult func ingest(_ fix: LocationFix, now: Date, uptime: TimeInterval) -> Bool {
        value.ingest(fix, now: now, uptime: uptime)
    }
    func ingest(_ sample: DrivingMotionSample, uptime: TimeInterval) { value.ingest(sample, uptime: uptime) }
    func pose(at time: TimeInterval) -> DrivingPose? { value.pose(at: time) }
    func reset() { value.reset() }
}
private func anchor(_ estimator: inout MotionEstimatorHarness, speed: Double = 10, course: Double = 0) {
    estimator.ingest(motionFix(speed: speed, course: course), now: motionEpoch, uptime: 100)
}

struct DrivingMotionEstimatorTests {
    @Test func sparseGPSProducesContinuousSpeedPrediction() throws {
        var estimator = MotionEstimatorHarness()
        anchor(&estimator)
        var previous = try #require(estimator.pose(at: 100))
        for frame in 1...30 {
            let pose = try #require(estimator.pose(at: 100 + Double(frame) / 30))
            let distance = previous.point.distance(to: pose.point)
            #expect(abs(distance - 10.0 / 30) < 0.01)
            previous = pose
        }
        #expect(abs(previous.point.distance(to: GeoPoint(latitude: 52, longitude: 5)) - 10) < 0.05)
        #expect(!previous.motionAssisted)
    }

    @Test func accelerationAndBrakingAssistBeforeNextGPS() throws {
        for acceleration in [2.0, -3.0] {
            var estimator = MotionEstimatorHarness()
            anchor(&estimator)
            for step in 0...50 {
                let t = 100 + Double(step) / 50
                estimator.ingest(motionSample(t, north: acceleration), uptime: t)
            }
            let pose = try #require(estimator.pose(at: 101))
            #expect(pose.motionAssisted)
            if acceleration > 0 { #expect(pose.predictedSpeed > 11.5) }
            else { #expect(pose.predictedSpeed < 7.8) }
        }
    }

    @Test func accelerationProjectsOntoTravelDirection() throws {
        var estimator = MotionEstimatorHarness()
        anchor(&estimator, course: 90)
        for step in 0...50 {
            let t = 100 + Double(step) / 50
            estimator.ingest(motionSample(t, north: 4, east: 0), uptime: t)
        }
        #expect(abs(try #require(estimator.pose(at: 101)).predictedSpeed - 10) < 0.01)
    }

    @Test func gravityAxisGyroTurnsAcrossNorthWithoutTakingLongWay() throws {
        var estimator = MotionEstimatorHarness()
        anchor(&estimator, course: 359)
        for step in 0...50 {
            let t = 100 + Double(step) / 50
            estimator.ingest(motionSample(t, yaw: 10 * .pi / 180), uptime: t)
        }
        let pose = try #require(estimator.pose(at: 101))
        #expect(abs(pose.heading - 9) < 0.1)
        #expect(pose.point.longitude > 5)
    }

    @Test func stationaryCarDoesNotCreepOrRotateFromSensors() throws {
        var estimator = MotionEstimatorHarness()
        anchor(&estimator, speed: 0)
        for step in 0...50 {
            let t = 100 + Double(step) / 50
            estimator.ingest(motionSample(t, north: 3, yaw: 0.5), uptime: t)
        }
        #expect(estimator.ingest(motionFix(1, north: 2, speed: 0, course: 180),
                                 now: motionEpoch.addingTimeInterval(1), uptime: 101))
        let pose = try #require(estimator.pose(at: 101.5))
        #expect(pose.point.distance(to: GeoPoint(latitude: 52, longitude: 5)) < 0.01)
        #expect(pose.heading == 0)
        #expect(pose.predictedSpeed == 0)
    }

    @Test func phoneTiltSuppressesMotionButKeepsGPSPrediction() throws {
        var estimator = MotionEstimatorHarness()
        anchor(&estimator)
        estimator.ingest(motionSample(100), uptime: 100)
        estimator.ingest(motionSample(100.02, north: 4, yaw: 0.7, gravityX: 1, gravityZ: 0), uptime: 100.02)
        for step in 2...25 {
            let t = 100 + Double(step) / 50
            estimator.ingest(motionSample(t, north: 4, yaw: 0.7, gravityX: 1, gravityZ: 0), uptime: t)
        }
        let pose = try #require(estimator.pose(at: 100.5))
        #expect(!pose.motionAssisted)
        #expect(pose.heading == 0)
        #expect(pose.predictedSpeed == 10)
        #expect(abs(pose.point.distance(to: GeoPoint(latitude: 52, longitude: 5)) - 5) < 0.05)
    }

    @Test func unreliableNorthReferenceStillAllowsGyroButNotAcceleration() throws {
        var estimator = MotionEstimatorHarness()
        anchor(&estimator)
        for step in 0...50 {
            let t = 100 + Double(step) / 50
            estimator.ingest(motionSample(t, north: nil, east: nil, yaw: 0.1), uptime: t)
        }
        let pose = try #require(estimator.pose(at: 101))
        #expect(abs(pose.predictedSpeed - 10) < 0.01)
        #expect(pose.heading > 5)
    }

    @Test func predictionFreezesAfterTwoSecondsIncludingCorrections() throws {
        var estimator = MotionEstimatorHarness()
        anchor(&estimator)
        let end = try #require(estimator.pose(at: 102))
        let later = try #require(estimator.pose(at: 120))
        #expect(end == later)
        #expect(end.predictionLimited)
        #expect(abs(end.point.distance(to: GeoPoint(latitude: 52, longitude: 5)) - 20) < 0.05)
    }

    @Test func ordinaryPositionAndHeadingCorrectionsDoNotJump() throws {
        var estimator = MotionEstimatorHarness()
        anchor(&estimator)
        let before = try #require(estimator.pose(at: 101))
        estimator.ingest(motionFix(1, north: 14, east: 4, course: 10),
                         now: motionEpoch.addingTimeInterval(1), uptime: 101)
        let immediately = try #require(estimator.pose(at: 101))
        #expect(before.point.distance(to: immediately.point) < 0.01)
        #expect(abs(before.heading - immediately.heading) < 0.01)
        let corrected = try #require(estimator.pose(at: 101.5))
        #expect(corrected.point.longitude > immediately.point.longitude)
        #expect(corrected.heading > 5)
    }

    @Test func isolatedOutlierRejectedAndConfirmedRelocationResets() throws {
        var estimator = MotionEstimatorHarness()
        anchor(&estimator)
        #expect(!estimator.ingest(motionFix(1, north: 1000, accuracy: 40), now: motionEpoch.addingTimeInterval(1), uptime: 101))
        let original = try #require(estimator.pose(at: 101))
        #expect(original.point.distance(to: GeoPoint(latitude: 52, longitude: 5)) < 20)
        #expect(!estimator.ingest(motionFix(2, north: 1010, accuracy: 5), now: motionEpoch.addingTimeInterval(2), uptime: 102))
        #expect(estimator.ingest(motionFix(3, north: 1020, accuracy: 5), now: motionEpoch.addingTimeInterval(3), uptime: 103))
        let relocated = try #require(estimator.pose(at: 103))
        #expect(relocated.point.distance(to: GeoPoint(latitude: 52, longitude: 5)) > 1000)
    }

    @Test func timestampsMappedToUptimeAndInvalidSamplesRejected() throws {
        let estimator = MotionEstimatorHarness()
        // A fix delivered 0.5 s late is projected to receipt time, not treated as brand-new GPS.
        #expect(estimator.ingest(motionFix(), now: motionEpoch.addingTimeInterval(0.5), uptime: 100.5))
        let pose = try #require(estimator.pose(at: 100.5))
        #expect(abs(pose.point.distance(to: GeoPoint(latitude: 52, longitude: 5)) - 5) < 0.05)
        #expect(!estimator.ingest(motionFix(), now: motionEpoch.addingTimeInterval(0.6), uptime: 100.6))
        #expect(!estimator.ingest(motionFix(20), now: motionEpoch, uptime: 101))
        estimator.ingest(motionSample(200, north: 100), uptime: 101)
        estimator.ingest(motionSample(100.7, yaw: .nan), uptime: 100.7)
        #expect(try #require(estimator.pose(at: 101)).predictedSpeed == 10)
        #expect(try #require(estimator.pose(at: 102)).predictionLimited)
    }

    @Test func missingCourseDoesNotPredictNorthAndResetClearsEverything() throws {
        var estimator = MotionEstimatorHarness()
        anchor(&estimator, course: -1)
        #expect(try #require(estimator.pose(at: 101)).point.distance(to: GeoPoint(latitude: 52, longitude: 5)) < 0.01)
        estimator.reset()
        #expect(estimator.pose(at: 102) == nil)
    }

    @Test func inaccurateCourseAndInvalidSpeedDisablePrediction() throws {
        for badCourse in [false, true] {
            let estimator = MotionEstimatorHarness()
            var fix = motionFix()
            if badCourse { fix.courseAccuracy = 90 }
            else { fix.speedAccuracy = -1 }
            estimator.ingest(fix, now: motionEpoch, uptime: 100)
            let pose = try #require(estimator.pose(at: 101))
            #expect(pose.predictedSpeed == 0)
            #expect(pose.point.distance(to: GeoPoint(latitude: 52, longitude: 5)) < 0.01)
        }
    }

    @Test func sensorDropoutStopsTurnIntegrationAndDateLineWraps() throws {
        var estimator = MotionEstimatorHarness()
        anchor(&estimator)
        estimator.ingest(motionSample(100, yaw: 0.5), uptime: 100)
        let early = try #require(estimator.pose(at: 100.3))
        let later = try #require(estimator.pose(at: 101))
        #expect(!later.motionAssisted)
        #expect(abs(early.heading - later.heading) < 0.001)
        let crossing = MotionEstimatorHarness()
        var fix = motionFix(speed: 30, course: 90)
        fix.latitude = 0; fix.longitude = 179.9999
        crossing.ingest(fix, now: motionEpoch, uptime: 100)
        let wrapped = try #require(crossing.pose(at: 101))
        #expect(wrapped.point.longitude < -179.999)
        #expect(wrapped.point.isValid)
    }

    @Test func tiltedPhoneAccelerationIsTransformedAndMagneticQualityGated() throws {
        let tilted = CMRotationMatrix(m11: 1, m12: 0, m13: 0,
                                      m21: 0, m22: 0, m23: 1,
                                      m31: 0, m32: -1, m33: 0)
        let projected = DrivingMotionTransform.northEast(x: 0, y: 0, z: 1,
            referenceToDevice: tilted, reliableNorth: true)
        #expect(abs(try #require(projected.north)) < 1e-8)
        #expect(abs(try #require(projected.east) - 9.80665) < 1e-8)
        let unreliable = DrivingMotionTransform.northEast(x: 1, y: 1, z: 1,
            referenceToDevice: tilted, reliableNorth: false)
        #expect(unreliable.north == nil)
        #expect(unreliable.east == nil)
    }
}

@MainActor private final class MotionTestClock: DrivingFrameClock {
    var frame: (() -> Void)?
    var running = false
    func start(_ frame: @escaping () -> Void) { self.frame = frame; running = true }
    func stop() { frame = nil; running = false }
}
@MainActor private final class MotionTestProvider: DrivingMotionProviding {
    var onSample: ((DrivingMotionSample) -> Void)?
    var starts = 0
    var stops = 0
    func start() { starts += 1 }
    func stop() { stops += 1 }
}

@MainActor struct DrivingMotionModelTests {
    @Test func lifecycleStopsSensorsClockAndRejectsOldSessionCallbacks() throws {
        let provider = MotionTestProvider(), clock = MotionTestClock()
        var uptime = 100.0
        let model = DrivingMotionModel(makeProvider: { provider }, clock: clock,
            uptime: { uptime }, now: { motionEpoch.addingTimeInterval(uptime - 100) })
        model.start(live: true)
        model.ingest(motionFix())
        let oldCallback = provider.onSample
        let oldFrame = clock.frame
        #expect(provider.starts == 1)
        uptime = 100.5; clock.frame?()
        #expect(try #require(model.pose).point.latitude > 52)
        model.stop()
        #expect(provider.stops == 1)
        #expect(!clock.running)
        #expect(provider.onSample == nil)
        #expect(model.pose == nil)
        model.start(live: false)
        oldCallback?(motionSample(100.5, north: 4))
        oldFrame?()
        #expect(provider.starts == 1)
        #expect(model.pose == nil)
        model.stop()
    }

    @Test func predictedFramesDoNotBecomeMeasuredFixesOrSpeed() throws {
        let clock = MotionTestClock(), motionProvider = MotionTestProvider()
        let location = MotionLocationStub()
        var uptime = 100.0
        let motion = DrivingMotionModel(makeProvider: { motionProvider }, clock: clock,
            uptime: { uptime }, now: { motionEpoch.addingTimeInterval(uptime - 100) })
        let driving = DrivingModel(makeProvider: { _ in location },
            now: { motionEpoch.addingTimeInterval(uptime - 100) }, motion: motion)
        driving.start(source: .live)
        location.onEvent?(.fix(motionFix()))
        let measured = driving.fix
        let measuredSpeed = driving.metersPerSecond
        uptime = 100.5; clock.frame?()
        #expect(driving.fix == measured)
        #expect(driving.metersPerSecond == measuredSpeed)
        #expect(try #require(motion.pose).point.latitude > measured!.latitude)
        driving.enterBackground()
        #expect(!clock.running)
        #expect(motionProvider.stops == 1)
        #expect(motion.pose == nil)
    }
}

@MainActor private final class MotionLocationStub: LocationProviding {
    var onEvent: ((LocationEvent) -> Void)?
    func start() {}
    func stop() {}
}
