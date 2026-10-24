import Foundation
import Testing
@testable import RoadScout

struct DrivingHeadingPresentationTests {
    private let epoch = Date(timeIntervalSince1970: 1_000)

    @Test func turnsAreResponsiveButFilteredAndSettleWithoutMultiSecondLag() {
        var heading = DrivingHeadingPresentation()
        heading.updateHeading(0, at: epoch)
        heading.updateHeading(90, at: epoch.addingTimeInterval(0.2))
        #expect(heading.cameraHeading > 35 && heading.cameraHeading < 55)
        for step in 2...8 { heading.updateHeading(90, at: epoch.addingTimeInterval(Double(step) * 0.2)) }
        #expect(heading.cameraHeading > 89.5 && heading.cameraHeading < 90)
    }

    @Test func crossingNorthUsesContinuousShortestPath() {
        var heading = DrivingHeadingPresentation()
        heading.updateHeading(359, at: epoch)
        let initial = heading.arrowRotation
        heading.updateHeading(1, at: epoch.addingTimeInterval(1))
        #expect(heading.heading > 359 && heading.heading < 361)
        #expect(abs(heading.arrowRotation - initial) < 2)
        heading.updateMapHeading(359)
        let before = heading.arrowRotation
        heading.updateMapHeading(1)
        #expect(abs(heading.arrowRotation - before + 2) < 0.00001)
    }

    @Test func actualCameraHeadingIsCompensatedWithoutFilteringItsFeedback() {
        var heading = DrivingHeadingPresentation()
        heading.updateHeading(90, at: epoch)
        heading.updateMapHeading(90)
        #expect(abs(heading.arrowRotation) < 0.00001)
        heading.updateMapHeading(45)
        #expect(abs(heading.arrowRotation - 45) < 0.00001)
    }

    @Test func invalidAndOutOfOrderSamplesDoNotChangeHeadingAndNewSessionResetsLag() {
        var heading = DrivingHeadingPresentation()
        heading.updateHeading(40, at: epoch)
        heading.updateHeading(.nan, at: epoch.addingTimeInterval(1))
        heading.updateHeading(.infinity, at: epoch.addingTimeInterval(1))
        heading.updateHeading(200, at: epoch.addingTimeInterval(-1))
        #expect(heading.cameraHeading == 40)
        heading.resetHeading(270, at: epoch.addingTimeInterval(2))
        #expect(heading.cameraHeading == 270)
        heading.updateHeading(280, at: epoch.addingTimeInterval(2))
        #expect(heading.cameraHeading == 270)
    }
}
