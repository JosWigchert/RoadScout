import Foundation
import Testing
@testable import RoadScout

private func dashboardRoute() throws -> DrivingRoute {
    try DrivingRoute(geometry: [GeoPoint(latitude: 52, longitude: 5), GeoPoint(latitude: 52.01, longitude: 5), GeoPoint(latitude: 52.02, longitude: 5.03)],
        distanceMeters: 24_000, durationSeconds: 1800,
        maneuvers: [RouteManeuver(id: "depart", instruction: "Start", spokenInstruction: "Start", beginIndex: 0, endIndex: 1,
                                  seconds: 1200, type: "depart", modifier: "straight"),
                    RouteManeuver(id: "left", instruction: "Turn left onto Nieuwe Steeg.", spokenInstruction: "Turn left",
                                  beginIndex: 1, endIndex: 2, seconds: 600, type: "turn", modifier: "left")])
}

private func dashboardProgress(index: Int = 1, arrived: Bool = false) -> NavigationProgress {
    NavigationProgress(traveledMeters: 6800, remainingMeters: 17_200, remainingSeconds: 1440,
                       maneuverIndex: index, maneuverDistance: 75, offRoute: false, arrived: arrived)
}

struct DrivingGuidancePresentationTests {
    @Test func activeCardUsesManeuverAndRemainingTripMetricsRatherThanWholeRoute() throws {
        let state = DrivingGuidancePresentation(route: try dashboardRoute(), progress: dashboardProgress(),
            isNavigating: true, isPaused: false, isLoading: false, hasDestination: true,
            destinationName: "Destination", message: nil)
        #expect(state.mode == .navigating)
        #expect(state.symbol == "arrow.turn.up.left")
        #expect(state.instruction == "Turn left onto Nieuwe Steeg.")
        #expect(state.maneuverDistance == 75)
        #expect(state.remainingMeters == 17_200)
        #expect(state.remainingSeconds == 1440)
        let now = Date(timeIntervalSince1970: 1000)
        #expect(state.arrival(at: now) == now.addingTimeInterval(1440))
        #expect(!state.canStart && !state.canRetry)
    }

    @Test func freeDriveDoesNotInventTripDataOrShowSpeedUnavailableBanner() {
        let state = DrivingGuidancePresentation(route: nil, progress: nil, isNavigating: false, isPaused: false,
            isLoading: false, hasDestination: false, destinationName: nil, message: "GPS speed unavailable")
        #expect(state.mode == .freeDrive)
        #expect(!state.showsTravelMetrics)
        #expect(state.arrival(at: .now) == nil)
        #expect(state.message == nil)
    }

    @Test func loadingAndFailureKeepRetryStateWithoutFakeETA() {
        let loading = DrivingGuidancePresentation(route: nil, progress: nil, isNavigating: false, isPaused: false,
            isLoading: true, hasDestination: true, destinationName: "Destination", message: nil)
        #expect(loading.mode == .loading && !loading.canRetry)
        #expect(!loading.showsTravelMetrics)
        let failure = DrivingGuidancePresentation(route: nil, progress: nil, isNavigating: false, isPaused: false,
            isLoading: false, hasDestination: true, destinationName: "Destination", message: "Routing unavailable")
        #expect(failure.mode == .unavailable && failure.canRetry)
        #expect(failure.message == "Routing unavailable")
        #expect(failure.arrival(at: .now) == nil)
    }

    @Test func pauseAndArrivalHaveDistinctActionsAndDoNotFabricateArrivalTimes() throws {
        let route = try dashboardRoute()
        let paused = DrivingGuidancePresentation(route: route, progress: dashboardProgress(), isNavigating: true,
            isPaused: true, isLoading: false, hasDestination: true, destinationName: "Destination", message: nil)
        #expect(paused.mode == .paused && paused.canStart)
        #expect(paused.arrival(at: .now) == nil)
        let arrived = DrivingGuidancePresentation(route: route, progress: dashboardProgress(arrived: true), isNavigating: false,
            isPaused: false, isLoading: false, hasDestination: true, destinationName: "Destination", message: "You have arrived")
        #expect(arrived.mode == .arrived && !arrived.canStart)
        #expect(!arrived.showsTravelMetrics)
        #expect(arrived.symbol == "flag.checkered")
    }

    @Test func reroutingKeepsCurrentInstructionAndInvalidManeuverIndexDoesNotCrash() throws {
        let route = try dashboardRoute()
        let rerouting = DrivingGuidancePresentation(route: route, progress: dashboardProgress(), isNavigating: true,
            isPaused: false, isLoading: true, hasDestination: true, destinationName: "Destination", message: "Off route")
        #expect(rerouting.mode == .navigating)
        #expect(rerouting.instruction == "Turn left onto Nieuwe Steeg.")
        #expect(rerouting.message == String(localized: "Recalculating route…"))
        let invalid = DrivingGuidancePresentation(route: route, progress: dashboardProgress(index: 999), isNavigating: true,
            isPaused: false, isLoading: false, hasDestination: true, destinationName: "Destination", message: nil)
        #expect(invalid.mode == .following && !invalid.canStart)
        #expect(invalid.maneuverDistance == nil)
    }
}
