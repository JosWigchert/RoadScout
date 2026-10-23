import Foundation
import MapKit
import Testing
@testable import RoadScout

private actor PlanningRouter: RoutingProviding {
    private(set) var requests: [RouteRequest] = []
    private var pending: [Int: CheckedContinuation<[DrivingRoute], Error>] = [:]
    func routes(for request: RouteRequest) async throws -> [DrivingRoute] {
        let index = requests.count
        requests.append(request)
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }
    func finish(_ index: Int, route: DrivingRoute) { pending.removeValue(forKey: index)?.resume(returning: [route]) }
}

@MainActor private final class PlanningAudio: AudioAnnouncing {
    func speak(_ text: String, language: String) { }
    func stop() { }
}

private func planningRoute(_ id: String) throws -> DrivingRoute {
    try DrivingRoute(geometry: [GeoPoint(latitude: 52, longitude: 5), GeoPoint(latitude: 52.1, longitude: 5.1)],
                     distanceMeters: 13_000, durationSeconds: 900,
                     maneuvers: [RouteManeuver(id: "depart", instruction: "Drive", spokenInstruction: "Drive",
                                              beginIndex: 0, endIndex: 1, seconds: 900, type: "depart", modifier: "straight")], id: id)
}

@MainActor private func awaitPlanning(_ predicate: () async -> Bool) async {
    for _ in 0..<500 {
        if await predicate() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
    #expect(await predicate())
}

@MainActor struct RoutePlanningTests {
    @Test func customOriginPreviewsWithoutGPSButCannotStartNavigationWithoutAFix() async throws {
        let router = PlanningRouter()
        let navigation = NavigationModel(audio: PlanningAudio(), provider: { _ in router })
        let planner = RoutePlanningModel()
        let start = Destination(name: "Different start", point: GeoPoint(latitude: 52.05, longitude: 5.05))
        let destination = Destination(name: "Finish", point: GeoPoint(latitude: 52.1, longitude: 5.1))
        planner.origin = .place(start)
        planner.preview(destination, currentLocation: nil, navigation: navigation, endpoint: "https://example.com", preferences: .init(avoidTolls: true))
        await awaitPlanning { await router.requests.count == 1 }
        let request = try #require(await router.requests.first)
        #expect(request.origin == start.point)
        #expect(request.destination == destination.point)
        #expect(request.originHeading == nil)
        #expect(request.preferences.avoidTolls)
        await router.finish(0, route: try planningRoute("custom"))
        await awaitPlanning { !navigation.isLoading }
        #expect(navigation.selectedRoute?.id == "custom")
        #expect(!navigation.isNavigating)
        navigation.start(fix: nil)
        #expect(!navigation.isNavigating)
    }

    @Test func changingOriginCancelsOldPreviewAndMyLocationUsesPhysicalCoordinates() async throws {
        let router = PlanningRouter()
        let navigation = NavigationModel(audio: PlanningAudio(), provider: { _ in router })
        let planner = RoutePlanningModel()
        let actual = GeoPoint(latitude: 52, longitude: 5)
        let custom = Destination(name: "Custom start", point: GeoPoint(latitude: 53, longitude: 6))
        let destination = Destination(name: "Finish", point: GeoPoint(latitude: 52.1, longitude: 5.1))
        planner.origin = .place(custom)
        planner.preview(destination, currentLocation: actual, navigation: navigation, endpoint: "https://example.com", preferences: .init())
        await awaitPlanning { await router.requests.count == 1 }
        planner.origin = .myLocation
        planner.preview(destination, currentLocation: actual, navigation: navigation, endpoint: "https://example.com", preferences: .init())
        await awaitPlanning { await router.requests.count == 2 }
        #expect(await router.requests[1].origin == actual)
        await router.finish(1, route: try planningRoute("current"))
        await awaitPlanning { navigation.selectedRoute?.id == "current" }
        await router.finish(0, route: try planningRoute("obsolete"))
        for _ in 0..<20 { await Task.yield() }
        #expect(navigation.selectedRoute?.id == "current")
        #expect(planner.originTitle == String(localized: "My location"))
    }

    @Test func missingOriginDoesNotInventCoordinatesAndIdenticalRequestsAreDeduplicated() async throws {
        let router = PlanningRouter()
        let navigation = NavigationModel(audio: PlanningAudio(), provider: { _ in router })
        let planner = RoutePlanningModel()
        let destination = Destination(name: "Finish", point: GeoPoint(latitude: 52.1, longitude: 5.1))
        planner.preview(destination, currentLocation: nil, navigation: navigation, endpoint: "https://example.com", preferences: .init())
        #expect(!navigation.isLoading)
        #expect(navigation.selectedRoute == nil)
        #expect(navigation.message != nil)
        #expect(await router.requests.isEmpty)
        let actual = GeoPoint(latitude: 52, longitude: 5)
        for _ in 0..<3 {
            planner.preview(destination, currentLocation: actual, navigation: navigation, endpoint: "https://example.com", preferences: .init())
        }
        await awaitPlanning { await router.requests.count == 1 }
        await router.finish(0, route: try planningRoute("once"))
        await awaitPlanning { !navigation.isLoading }
        planner.preview(destination, currentLocation: actual, navigation: navigation, endpoint: "https://example.com", preferences: .init())
        #expect(await router.requests.count == 1)
        planner.origin = .place(destination)
        planner.isEditingOrigin = true
        planner.reset()
        #expect(planner.origin == .myLocation)
        #expect(!planner.isEditingOrigin)
        #expect(RoutePlanningProfile.allCases == [.fastest])
    }
}

struct RoutePreviewViewportTests {
    @Test(arguments: [CGSize(width: 402, height: 874), CGSize(width: 874, height: 402)])
    func fullRouteFitsAboveSheetInBothOrientations(viewport: CGSize) {
        let shapes = [
            [GeoPoint(latitude: 52, longitude: 4), GeoPoint(latitude: 52.1, longitude: 6)],
            [GeoPoint(latitude: 51, longitude: 5), GeoPoint(latitude: 53, longitude: 5.01)],
            [GeoPoint(latitude: 52, longitude: 5), GeoPoint(latitude: 52.0001, longitude: 5.0001)]
        ]
        for shape in shapes {
            let rect = PlaceMapFocus.routeRect(for: shape, viewport: viewport)
            #expect(rect.width.isFinite && rect.height.isFinite)
            for coordinate in shape {
                let point = MKMapPoint(coordinate.coordinate)
                let x = (point.x - rect.minX) / rect.width
                let y = (point.y - rect.minY) / rect.height
                #expect(x > 0 && x < 1)
                #expect(y > 0 && y <= 0.401)
            }
        }
    }

    @Test func datelineRouteDoesNotZoomOutToWholeWorld() {
        let rect = PlaceMapFocus.routeRect(for: [GeoPoint(latitude: 50, longitude: 179.8), GeoPoint(latitude: 50, longitude: -179.8)],
                                          viewport: CGSize(width: 402, height: 874))
        #expect(rect.width < MKMapRect.world.width / 10)
    }

    @Test func labelPlacementUsesDistanceAlongRouteRatherThanVertexCount() throws {
        let route = try planningRoute("label")
        let halfway = PlaceMapFocus.labelPoint(on: route, fraction: 0.5)
        #expect(abs(halfway.latitude - 52.05) < 0.00001)
        #expect(abs(halfway.longitude - 5.05) < 0.00001)
    }
}
