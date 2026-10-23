import Foundation
import Testing
@testable import RoadScout

func sampleFix(speed: Double = 10, time: TimeInterval = 0) -> LocationFix {
    LocationFix(latitude: 52, longitude: 5, speed: speed, speedAccuracy: 0.5,
                horizontalAccuracy: 5, course: 0,
                timestamp: Date(timeIntervalSince1970: 1_800_000_000 + time))
}

struct SpeedProcessorTests {
    @Test func unitConversions() {
        #expect(abs(SpeedUnit.kilometersPerHour.convert(metersPerSecond: 10) - 36) < 0.0001)
        #expect(abs(SpeedUnit.milesPerHour.convert(metersPerSecond: 10) - 22.369362921) < 0.0001)
    }

    @Test(arguments: [-1.0, Double.nan, Double.infinity])
    func invalidSpeedsAreUnknown(speed: Double) {
        var processor = SpeedProcessor()
        let fix = sampleFix(speed: speed)
        processor.ingest(fix, now: fix.timestamp)
        #expect(processor.metersPerSecond == nil)
    }

    @Test(arguments: [-1.0, 51.0, Double.nan, Double.infinity])
    func inaccuratePositionIsUnknown(accuracy: Double) {
        var processor = SpeedProcessor()
        var fix = sampleFix()
        fix.horizontalAccuracy = accuracy
        processor.ingest(fix, now: fix.timestamp)
        #expect(processor.metersPerSecond == nil)
    }

    @Test(arguments: [-1.0, 3.1, Double.nan, Double.infinity])
    func inaccurateSpeedIsUnknown(accuracy: Double) {
        var processor = SpeedProcessor()
        var fix = sampleFix()
        fix.speedAccuracy = accuracy
        processor.ingest(fix, now: fix.timestamp)
        #expect(processor.metersPerSecond == nil)
    }

    @Test func staleAndFutureReadingsAreRejected() {
        var processor = SpeedProcessor()
        let fix = sampleFix()
        processor.ingest(fix, now: fix.timestamp.addingTimeInterval(6))
        #expect(processor.metersPerSecond == nil)
        processor.reset()
        processor.ingest(fix, now: fix.timestamp.addingTimeInterval(-2))
        #expect(processor.metersPerSecond == nil)
        let next = sampleFix(speed: 12, time: -1)
        processor.ingest(next, now: next.timestamp)
        #expect(processor.metersPerSecond == 12)
    }

    @Test func smallJitterIsSmoothedButAccelerationAndStoppingAreImmediate() throws {
        var processor = SpeedProcessor()
        let first = sampleFix()
        processor.ingest(first, now: first.timestamp)
        let jitter = sampleFix(speed: 11, time: 0.2)
        processor.ingest(jitter, now: jitter.timestamp)
        let smoothed = try #require(processor.metersPerSecond)
        #expect(smoothed > 10 && smoothed < 11)
        let accelerating = sampleFix(speed: 16, time: 1)
        processor.ingest(accelerating, now: accelerating.timestamp)
        #expect(processor.metersPerSecond == 16)
        let stop = sampleFix(speed: 0, time: 2)
        processor.ingest(stop, now: stop.timestamp)
        #expect(processor.metersPerSecond == 0)
    }

    @Test func invalidFixClearsSpeedAndRecoveryDoesNotReuseHistory() {
        var processor = SpeedProcessor()
        for (time, speed) in [(0.0, 10.0), (1, -1), (2, 11)] {
            let fix = sampleFix(speed: speed, time: time)
            processor.ingest(fix, now: fix.timestamp)
            #expect(processor.metersPerSecond == (speed < 0 ? nil : speed))
        }
    }

    @Test func duplicateAndOutOfOrderSamplesCannotChangeSpeed() {
        var processor = SpeedProcessor()
        let fix = sampleFix(speed: 12, time: 2)
        processor.ingest(fix, now: fix.timestamp)
        processor.ingest(sampleFix(speed: 99, time: 2), now: fix.timestamp)
        processor.ingest(sampleFix(speed: -1, time: 1), now: fix.timestamp)
        #expect(processor.metersPerSecond == 12)
    }

    @Test func expiryAndResetClearSpeed() {
        var processor = SpeedProcessor()
        let fix = sampleFix()
        processor.ingest(fix, now: fix.timestamp)
        processor.expire(at: fix.timestamp.addingTimeInterval(5))
        #expect(processor.metersPerSecond == 10)
        processor.expire(at: fix.timestamp.addingTimeInterval(5.1))
        #expect(processor.metersPerSecond == nil)
        processor.reset()
        processor.ingest(fix, now: fix.timestamp)
        #expect(processor.metersPerSecond == 10)
    }

    @Test func invalidCoordinatesAreRejected() {
        var processor = SpeedProcessor()
        var fix = sampleFix()
        fix.latitude = 91
        processor.ingest(fix, now: fix.timestamp)
        #expect(processor.metersPerSecond == nil)
    }
}
