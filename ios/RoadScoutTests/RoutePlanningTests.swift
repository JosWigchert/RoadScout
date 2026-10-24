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
    func finish(_ index: Int, routes: [DrivingRoute]) { pending.removeValue(forKey: index)?.resume(returning: routes) }
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
        planner.profile = .moreCorners
        planner.maxExtraDurationPercent = 50
        planner.preview(destination, currentLocation: nil, navigation: navigation, endpoint: "https://example.com", preferences: .init(avoidTolls: true))
        await awaitPlanning { await router.requests.count == 1 }
        let request = try #require(await router.requests.first)
        #expect(request.origin == start.point)
        #expect(request.destination == destination.point)
        #expect(request.originHeading == nil)
        #expect(request.preferences.avoidTolls)
        #expect(request.objective == .moreCorners)
        #expect(request.maxExtraDurationPercent == 50)
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
        #expect(planner.profile == .fastest)
        #expect(!planner.canChooseStyle)
        #expect(planner.detourOptions.isEmpty)
    }

    @Test(arguments: [15, 50, 85, 100]) func objectiveAndDetourBudgetSurviveTheFreshGPSRecalculation(budget: Int) async throws {
        let router = PlanningRouter()
        let fix = sampleFix()
        let navigation = NavigationModel(audio: PlanningAudio(), provider: { _ in router }, now: { fix.timestamp })
        let planner = RoutePlanningModel()
        planner.profile = .scenic
        planner.maxExtraDurationPercent = budget
        planner.preview(Destination(name: "Finish", point: GeoPoint(latitude: 52.1, longitude: 5.1)),
                        currentLocation: GeoPoint(latitude: 53, longitude: 6), navigation: navigation,
                        endpoint: "https://example.com", preferences: .init())
        await awaitPlanning { await router.requests.count == 1 }
        await router.finish(0, route: try planningRoute("preview"))
        await awaitPlanning { !navigation.isLoading }
        navigation.refreshFromGPS(fix)
        await awaitPlanning { await router.requests.count == 2 }
        let request = await router.requests[1]
        #expect(request.origin == GeoPoint(latitude: fix.latitude, longitude: fix.longitude))
        #expect(request.objective == .scenic)
        #expect(request.maxExtraDurationPercent == budget)
        await router.finish(1, route: try planningRoute("live"))
        await awaitPlanning { !navigation.isLoading }
    }

    @Test(arguments: [85, 100]) func routePreferencesSurviveTripTeardownAndRelaunch(budget: Int) throws {
        let suite = "RoadScout.RoutePreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let planner = RoutePlanningModel(defaults: defaults)
        planner.apply(options: [.fastest, RouteOption(id: "more_corners", isExperimental: true)])
        let style = RoutePlanningProfile.moreCorners
        planner.profile = style
        planner.maxExtraDurationPercent = budget
        planner.origin = .place(Destination(name: "Temporary start", point: GeoPoint(latitude: 52, longitude: 5)))
        planner.isEditingOrigin = true
        planner.clearTrip()
        #expect(planner.profile == style)
        #expect(planner.maxExtraDurationPercent == budget)
        #expect(planner.origin == .myLocation)
        #expect(!planner.isEditingOrigin)
        let reloaded = RoutePlanningModel(defaults: defaults)
        reloaded.apply(options: [.fastest, RouteOption(id: "more_corners", isExperimental: true)])
        #expect(reloaded.profile == style)
        #expect(reloaded.maxExtraDurationPercent == budget)
        #expect(reloaded.detourOptions.contains(85) && reloaded.detourOptions.contains(100))
    }

    @Test func storedPreferencesAreReconciledWithServerCatalog() throws {
        let suite = "RoadScout.RoutePreferenceReconcileTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("future_profile", forKey: "routePlanningProfile")
        defaults.set(200, forKey: "routePlanningDetourPercent")
        let planner = RoutePlanningModel(defaults: defaults)
        planner.apply(options: [.fastest])
        #expect(planner.profile == .fastest && !planner.canChooseStyle)
        planner.apply(options: [.fastest, RouteOption(id: "more_corners", isExperimental: true)])
        planner.profile = .moreCorners
        #expect(planner.maxExtraDurationPercent == RouteOption.defaultDetourOptions.first)
        #expect(planner.detourOptions == RouteOption.defaultDetourOptions)
        #expect(defaults.string(forKey: "routePlanningProfile") == "more_corners")
    }

    @Test func selectedAlternativeIsKeptNearItsOriginAndRecalculatedOnlyAfterMoving() async throws {
        let router = PlanningRouter()
        let fix = sampleFix()
        let navigation = NavigationModel(audio: PlanningAudio(), provider: { _ in router }, now: { fix.timestamp })
        let destination = Destination(name: "Finish", point: GeoPoint(latitude: 52.1, longitude: 5.1))
        navigation.preview(destination, origin: GeoPoint(latitude: 52, longitude: 5), endpoint: "https://example.com", preferences: .init())
        await awaitPlanning { await router.requests.count == 1 }
        let first = try planningRoute("first")
        let alternative = try planningRoute("chosen")
        await router.finish(0, routes: [first, alternative])
        await awaitPlanning { !navigation.isLoading }
        navigation.select(alternative)
        var stale = fix; stale.timestamp = fix.timestamp.addingTimeInterval(-10)
        #expect(!navigation.startPreviewOrRecalculate(fix: stale))
        #expect(!navigation.isNavigating)
        #expect(navigation.startPreviewOrRecalculate(fix: fix))
        #expect(navigation.selectedRoute?.id == "chosen")
        #expect(await router.requests.count == 1)
        navigation.pause()
        var moved = fix; moved.latitude += 0.02
        #expect(!navigation.startPreviewOrRecalculate(fix: moved))
        await awaitPlanning { await router.requests.count == 2 }
        #expect(await router.requests[1].origin == GeoPoint(latitude: moved.latitude, longitude: moved.longitude))
        await router.finish(1, route: try planningRoute("recalculated"))
        await awaitPlanning { !navigation.isLoading }
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
