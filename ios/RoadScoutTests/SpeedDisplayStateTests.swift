import Foundation
import Testing
@testable import RoadScout

struct SpeedDisplayStateTests {
    @Test(arguments: SpeedUnit.allCases)
    func limitComparisonDoesNotDependOnSelectedUnits(unit: SpeedUnit) {
        let limit = 50.0 / 3.6
        #expect(!SpeedDisplayState(metersPerSecond: limit - 1, limitMetersPerSecond: limit, unit: unit).isOverLimit)
        #expect(!SpeedDisplayState(metersPerSecond: limit, limitMetersPerSecond: limit, unit: unit).isOverLimit)
        #expect(SpeedDisplayState(metersPerSecond: limit + 1, limitMetersPerSecond: limit, unit: unit).isOverLimit)
    }

    @Test(arguments: [nil, -1, 0, Double.nan, Double.infinity] as [Double?])
    func unknownOrInvalidLimitsNeverAssertOverspeed(limit: Double?) {
        let display = SpeedDisplayState(metersPerSecond: 30, limitMetersPerSecond: limit, unit: .kilometersPerHour)
        #expect(!display.isOverLimit)
        #expect(display.limitText == "—")
    }

    @Test(arguments: [nil, -1, Double.nan, Double.infinity] as [Double?])
    func unknownOrInvalidSpeedDoesNotShowZeroOrOverspeed(speed: Double?) {
        let display = SpeedDisplayState(metersPerSecond: speed, limitMetersPerSecond: 10, unit: .milesPerHour)
        #expect(display.speedText == "—")
        #expect(!display.isOverLimit)
    }

    @Test func displayUsesSettingsUnitAndDistinguishesStoppedFromUnknown() {
        let metric = SpeedDisplayState(metersPerSecond: 26.8224, unit: .kilometersPerHour)
        let imperial = SpeedDisplayState(metersPerSecond: 26.8224, unit: .milesPerHour)
        #expect(metric.speedText == 97.formatted())
        #expect(imperial.speedText == 60.formatted())
        #expect(SpeedDisplayState(metersPerSecond: 0, unit: .kilometersPerHour).speedText == 0.formatted())
    }
}
