import Foundation
import Testing
@testable import RoadScout

private let trafficEpoch = Date(timeIntervalSince1970: 1_800_000_000)
private func trafficRoute(_ id: String = "current", seconds: Double = 900, mode: String = "live_partial", key: String = "corridor") throws -> DrivingRoute {
    try DrivingRoute(geometry: [GeoPoint(latitude: 52, longitude: 5), GeoPoint(latitude: 52.01, longitude: 5), GeoPoint(latitude: 52.02, longitude: 5)],
        distanceMeters: 2224, durationSeconds: seconds,
        maneuvers: [RouteManeuver(id: "depart", instruction: "Drive", spokenInstruction: "Drive", beginIndex: 0, endIndex: 2, seconds: seconds, type: "depart", modifier: "straight")],
        id: id, traffic: RouteTrafficMetadata(mode: mode, token: id, corridorKey: key, leadMeters: 2000,
            coveragePercent: 50, expiresAt: trafficEpoch.addingTimeInterval(2000)))
}

private func trafficFeatureFixture(_ id: String, title: String = "Jam", observedAt: Date = trafficEpoch,
                                   congestion: String = "heavy") throws -> TrafficFeature {
    let object: [String: Any] = ["id": id, "sourceId": "test", "kind": "flow", "title": title,
        "geometry": ["encoding": "polyline6", "data": CameraRouteGeometry.encode([GeoPoint(latitude: 52, longitude: 5), GeoPoint(latitude: 52.001, longitude: 5)])],
        "observedAt": WeatherWireDate.string(from: observedAt), "matched": true, "congestion": congestion]
    return try JSONDecoder().decode(TrafficFeature.self, from: JSONSerialization.data(withJSONObject: object))
}

private func trafficResponse(_ features: [TrafficFeature]) -> TrafficMapResponse {
    TrafficMapResponse(sources: [], features: features, routingEnabled: false, truncated: false)
}

private actor OfflineTrafficClient: TrafficProviding {
    func fetch(bounds: CameraBounds, route: DrivingRoute?, endpoint: String) async throws -> TrafficMapResponse {
        throw TrafficClientError.unavailable
    }
    func refresh(route: DrivingRoute, fix: LocationFix, traveledMeters: Double, checkAlternatives: Bool, endpoint: String) async throws -> TrafficRefresh {
        throw TrafficClientError.unavailable
    }
}

private actor TrafficCacheStub: TrafficCaching {
    let entry: TrafficCacheEntry?
    private(set) var loads = 0
    init(entry: TrafficCacheEntry?) { self.entry = entry }
    func load(scope: TrafficCacheScope) async throws -> TrafficCacheEntry? {
        loads += 1
        return entry?.scope == scope ? entry : nil
    }
    func loadLatest(endpoint: String) async throws -> TrafficCacheEntry? {
        loads += 1
        return entry?.scope.endpoint == endpoint ? entry : nil
    }
    func save(_ entry: TrafficCacheEntry) async throws {}
}

private actor MapTrafficSequence: TrafficProviding {
    let responses: [TrafficMapResponse]
    private(set) var bounds: [CameraBounds] = []
    init(_ responses: [TrafficMapResponse]) { self.responses = responses }
    func fetch(bounds: CameraBounds, route: DrivingRoute?, endpoint: String) -> TrafficMapResponse {
        self.bounds.append(bounds)
        return responses[min(self.bounds.count - 1, responses.count - 1)]
    }
    func refresh(route: DrivingRoute, fix: LocationFix, traveledMeters: Double, checkAlternatives: Bool, endpoint: String) throws -> TrafficRefresh {
        throw TrafficClientError.unavailable
    }
}

struct TrafficOfferPolicyTests {
    @Test func confirmationCountdownAndRejectionCooldown() throws {
        let route = try trafficRoute("alternative", seconds: 600)
        var policy = TrafficOfferPolicy()
        policy.propose(route: route, currentSeconds: 900, now: trafficEpoch, uptime: 100)
        #expect(policy.offer == nil)
        policy.propose(route: route, currentSeconds: 900, now: trafficEpoch.addingTimeInterval(60), uptime: 160)
        #expect(policy.offer?.deadline == 175)
        #expect(policy.offer?.savingSeconds == 300)
        policy.reject(uptime: 161)
        policy.propose(route: route, currentSeconds: 900, now: trafficEpoch.addingTimeInterval(120), uptime: 220)
        #expect(policy.offer == nil)
        policy.propose(route: route, currentSeconds: 900, now: trafficEpoch.addingTimeInterval(700), uptime: 800)
        policy.propose(route: route, currentSeconds: 900, now: trafficEpoch.addingTimeInterval(760), uptime: 860)
        #expect(policy.offer != nil)
    }

    @Test func insufficientSavingUnsupportedRoutingAndExpiredDataCannotOffer() throws {
        for (seconds, mode, now) in [(850.0, "live_partial", trafficEpoch), (600, "unavailable", trafficEpoch), (600, "live_partial", trafficEpoch.addingTimeInterval(2001))] {
            let route = try trafficRoute("alternative", seconds: seconds, mode: mode)
            var policy = TrafficOfferPolicy()
            policy.propose(route: route, currentSeconds: 900, now: now, uptime: 100)
            policy.propose(route: route, currentSeconds: 900, now: now.addingTimeInterval(60), uptime: 160)
            #expect(policy.offer == nil)
        }
    }

    @Test func hiddenOfferCancelsCountdownAndStaleConfirmationIsNotReused() throws {
        let route = try trafficRoute("alternative", seconds: 600)
        var policy = TrafficOfferPolicy()
        policy.propose(route: route, currentSeconds: 900, now: trafficEpoch, uptime: 100)
        policy.propose(route: route, currentSeconds: 900, now: trafficEpoch.addingTimeInterval(300), uptime: 400)
        #expect(policy.offer == nil)
        policy.propose(route: route, currentSeconds: 900, now: trafficEpoch.addingTimeInterval(360), uptime: 460)
        #expect(policy.offer != nil)
        policy.cancel()
        #expect(policy.offer == nil)
    }
}

private actor TrafficStub: TrafficProviding {
    private(set) var refreshes = 0
    var response: TrafficRefresh
    init(response: TrafficRefresh) { self.response = response }
    func fetch(bounds: CameraBounds, route: DrivingRoute?, endpoint: String) -> TrafficMapResponse {
        TrafficMapResponse(sources: [], features: [], routingEnabled: false, truncated: false)
    }
    func refresh(route: DrivingRoute, fix: LocationFix, traveledMeters: Double, checkAlternatives: Bool, endpoint: String) -> TrafficRefresh { refreshes += 1; return response }
}
private actor TrafficRouter: RoutingProviding {
    let route: DrivingRoute
    init(route: DrivingRoute) { self.route = route }
    func routes(for request: RouteRequest) -> [DrivingRoute] { [route] }
}
@MainActor private final class TrafficAudio: AudioAnnouncing {
    func speak(_ text: String, language: String) {}
    func stop() {}
}
@MainActor private final class TrafficClock {
    var now = trafficEpoch
    var uptime = 100.0
    func advance(_ seconds: Double) { now += seconds; uptime += seconds }
    var fix: LocationFix { LocationFix(latitude: 52, longitude: 5, speed: 10, speedAccuracy: 1, horizontalAccuracy: 5, course: 0, timestamp: now) }
}
@MainActor private func awaitTraffic(_ condition: () async -> Bool) async {
    for _ in 0..<500 { if await condition() { return }; try? await Task.sleep(for: .milliseconds(1)) }
    #expect(await condition())
}
@MainActor private func startedTrafficNavigation(_ clock: TrafficClock) async throws -> NavigationModel {
    let route = try trafficRoute(), router = TrafficRouter(route: route)
    let navigation = NavigationModel(audio: TrafficAudio(), provider: { _ in router }, now: { clock.now })
    navigation.preview(Destination(name: "Destination", point: route.geometry.last!), fix: clock.fix,
        endpoint: "https://example.com", preferences: .init())
    await awaitTraffic { !navigation.isLoading }
    navigation.start(fix: clock.fix)
    return navigation
}

@MainActor struct TrafficModelTests {
    @Test func populatedMapDoesNotReloadDiskCacheOnPanOrRefresh() async throws {
        let clock = TrafficClock()
        let cache = TrafficCacheStub(entry: nil)
        let client = MapTrafficSequence([trafficResponse([try trafficFeatureFixture("live")])])
        let model = TrafficModel(client: client, cache: cache, now: { clock.now })
        let bounds = CameraBounds(south: 51.99, west: 4.99, north: 52.01, east: 5.01)
        model.fetchMap(bounds: bounds, route: nil, endpoint: "https://example.com")
        await awaitTraffic { model.map?.features.count == 1 }
        let initialLoads = await cache.loads
        clock.advance(61)
        model.fetchMap(bounds: bounds, route: nil, endpoint: "https://example.com")
        await awaitTraffic { await client.bounds.count == 2 }
        #expect(await cache.loads == initialLoads)
        model.clear()
    }

    @Test func truncatedSnapshotsCannotKeepExpiredTraffic() async throws {
        let clock = TrafficClock()
        let partial = TrafficMapResponse(sources: [], features: [], routingEnabled: false, truncated: true)
        let client = MapTrafficSequence([trafficResponse([try trafficFeatureFixture("old")]), partial])
        let model = TrafficModel(client: client, cache: TrafficCacheStub(entry: nil), now: { clock.now })
        let bounds = CameraBounds(south: 51.99, west: 4.99, north: 52.01, east: 5.01)
        model.fetchMap(bounds: bounds, route: nil, endpoint: "https://example.com")
        await awaitTraffic { model.map?.features.count == 1 }
        clock.advance(181)
        model.fetchMap(bounds: bounds, route: nil, endpoint: "https://example.com")
        await awaitTraffic { model.map?.features.isEmpty == true }
        model.clear()
    }

    @Test func bufferedAreaReusesRequestsAndRefreshesAfterOneMinute() async throws {
        let clock = TrafficClock()
        let client = MapTrafficSequence([trafficResponse([try trafficFeatureFixture("live")])])
        let model = TrafficModel(client: client, cache: TrafficCacheStub(entry: nil), now: { clock.now })
        let bounds = CameraBounds(south: 51.99, west: 4.99, north: 52.01, east: 5.01)
        model.fetchMap(bounds: bounds, route: nil, endpoint: "https://example.com")
        await awaitTraffic { model.map?.features.count == 1 }
        for offset in 1...10 {
            let delta = Double(offset) * 0.001
            model.fetchMap(bounds: CameraBounds(south: bounds.south + delta, west: bounds.west + delta,
                                               north: bounds.north + delta, east: bounds.east + delta),
                           route: nil, endpoint: "https://example.com")
        }
        #expect(await client.bounds.count == 1)
        #expect(await client.bounds.first?.contains(bounds) == true)
        clock.advance(61)
        model.fetchMap(bounds: bounds, route: nil, endpoint: "https://example.com")
        await awaitTraffic { await client.bounds.count == 2 }
        model.clear()
    }

    @Test func partialSnapshotsRetainFreshMissingRecordsButCompleteSnapshotsRemoveThem() async throws {
        let clock = TrafficClock()
        let first = trafficResponse([try trafficFeatureFixture("a")])
        let partial = TrafficMapResponse(sources: [], features: [try trafficFeatureFixture("b")], routingEnabled: false, truncated: true)
        let client = MapTrafficSequence([first, partial, trafficResponse([])])
        let model = TrafficModel(client: client, cache: TrafficCacheStub(entry: nil), now: { clock.now })
        let bounds = CameraBounds(south: 51.99, west: 4.99, north: 52.01, east: 5.01)
        model.fetchMap(bounds: bounds, route: nil, endpoint: "https://example.com")
        await awaitTraffic { model.map?.features.map(\.id) == ["a"] }
        clock.advance(61)
        model.fetchMap(bounds: bounds, route: nil, endpoint: "https://example.com")
        await awaitTraffic { model.map?.features.map(\.id) == ["a", "b"] }
        clock.advance(61)
        model.fetchMap(bounds: bounds, route: nil, endpoint: "https://example.com")
        await awaitTraffic { model.map?.features.isEmpty == true }
        model.clear()
    }

    @Test func overviewTrafficStrokesAreThinnerThanStreetLevel() {
        let close = CameraBounds(south: 52, west: 5, north: 52.01, east: 5.01)
        let wide = CameraBounds(south: 51, west: 4, north: 53, east: 6)
        #expect(MapDisplayScale.flowWidth(in: wide) == 1.5)
        #expect(MapDisplayScale.flowWidth(in: wide) < MapDisplayScale.flowWidth(in: close))
        #expect(MapDisplayScale.closureWidth(in: close) < MapDisplayScale.flowWidth(in: close))
    }

    @Test func timeoutRevalidatesAndSwitchesButBackgroundCancels() async throws {
        for background in [false, true] {
            let clock = TrafficClock(), navigation = try await startedTrafficNavigation(clock)
            let alternative = try trafficRoute("alternative", seconds: 600)
            let client = TrafficStub(response: TrafficRefresh(routingEnabled: true, remainingSeconds: 900,
                expiresAt: trafficEpoch.addingTimeInterval(1000), alternatives: [alternative]))
            let model = TrafficModel(client: client, now: { clock.now }, uptime: { clock.uptime })
            model.consume(fix: clock.fix, navigation: navigation, endpoint: "https://example.com", foreground: true)
            await awaitTraffic { !model.checking }
            #expect(model.offer == nil)
            clock.advance(60); navigation.consume(clock.fix)
            model.consume(fix: clock.fix, navigation: navigation, endpoint: "https://example.com", foreground: true)
            await awaitTraffic { model.offer != nil }
            if background { model.setVisible(false) }
            clock.advance(16); navigation.consume(clock.fix)
            model.consume(fix: clock.fix, navigation: navigation, endpoint: "https://example.com", foreground: !background)
            if background { #expect(navigation.selectedRoute?.id == "current"); #expect(model.offer == nil) }
            else { await awaitTraffic { navigation.selectedRoute?.id == "alternative" }; #expect(await client.refreshes == 3) }
            model.endSession(); navigation.end()
        }
    }

    @Test func unavailableServerCannotOfferOrReplaceLoadedRoute() async throws {
        let clock = TrafficClock(), navigation = try await startedTrafficNavigation(clock)
        let client = TrafficStub(response: TrafficRefresh())
        let model = TrafficModel(client: client, now: { clock.now }, uptime: { clock.uptime })
        model.consume(fix: clock.fix, navigation: navigation, endpoint: "https://example.com", foreground: true)
        await awaitTraffic { !model.checking }
        #expect(model.offer == nil)
        #expect(navigation.isNavigating)
        #expect(navigation.selectedRoute?.id == "current")
        navigation.end(); model.endSession()
    }

    @Test func trafficETARefreshPreservesProgressAndExpires() async throws {
        let clock = TrafficClock(), navigation = try await startedTrafficNavigation(clock)
        let before = try #require(navigation.progress)
        navigation.applyTrafficETA(routeID: "current", seconds: 1200, expiresAt: clock.now.addingTimeInterval(90))
        #expect(navigation.progress?.traveledMeters == before.traveledMeters)
        #expect(navigation.progress?.remainingSeconds == 1200)
        clock.advance(10)
        var fix = clock.fix; fix.latitude += 0.0005
        navigation.consume(fix)
        #expect(navigation.progress?.traveledMeters ?? 0 > before.traveledMeters)
        #expect(navigation.progress?.remainingSeconds ?? 0 > 1100)
        clock.advance(100); fix.timestamp = clock.now; fix.latitude += 0.0005
        navigation.consume(fix)
        #expect(navigation.progress?.remainingSeconds ?? 1000 < 900)
        navigation.end()
    }

    @Test func cachedTrafficSurvivesOfflineFetch() async throws {
        let feature = try trafficFeatureFixture("cached")
        let response = trafficResponse([feature])
        let scope = TrafficCacheScope(endpoint: "https://example.com",
                                      bounds: CameraBounds(south: 51, west: 4, north: 53, east: 6), routeID: nil)
        let entry = TrafficCacheEntry(scope: scope, fetchedAt: trafficEpoch, response: response)
        let model = TrafficModel(client: OfflineTrafficClient(), cache: TrafficCacheStub(entry: entry),
                                 now: { trafficEpoch })
        model.fetchMap(bounds: scope.bounds, route: nil, endpoint: scope.endpoint)
        await awaitTraffic { model.map?.features.count == 1 }
        #expect(model.map?.features.first?.id == "cached")
        #expect(model.status?.contains("cached") == true)
    }
}

struct TrafficCacheTests {
    @Test func diskCacheRoundTripsFeaturesAndFindsLatestEndpointEntry() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent("RoadScoutTrafficCache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = TrafficDiskCache(directory: directory, maximumEntries: 4, maximumBytes: 200_000)
        let feature = try trafficFeatureFixture("cached")
        let response = trafficResponse([feature])
        let scope = TrafficCacheScope(endpoint: "https://example.com",
                                      bounds: CameraBounds(south: 51, west: 4, north: 53, east: 6), routeID: "route")
        try await cache.save(TrafficCacheEntry(scope: scope, fetchedAt: trafficEpoch, response: response))
        let loaded = try #require(try await cache.load(scope: scope))
        #expect(loaded.response == response)
        #expect(loaded.response.features.first?.points == feature.points)
        let latest = try #require(try await cache.loadLatest(endpoint: scope.endpoint))
        #expect(latest.scope == scope)
    }
}

struct TrafficDecodingTests {
    @Test func pointIncidentDoesNotInvalidateTrafficResponse() throws {
        let geometry = CameraRouteGeometry.encode([GeoPoint(latitude: 52, longitude: 5)])
        let object: [String: Any] = ["sources": [], "routingEnabled": false, "truncated": false,
            "features": [["id": "incident", "sourceId": "ndw", "kind": "incident", "title": "Incident",
                          "geometry": ["encoding": "polyline6", "data": geometry],
                          "observedAt": "2026-10-28T12:00:00Z", "matched": false]]]
        let response = try JSONDecoder().decode(TrafficMapResponse.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(response.features.first?.points.count == 1)
        #expect(throws: RoutingError.self) { try Polyline6.decode(geometry) }
    }
    @Test func closurePresentationUsesGeometryEndpoints() throws {
        let points = [GeoPoint(latitude: 52, longitude: 5), GeoPoint(latitude: 52.001, longitude: 5),
                      GeoPoint(latitude: 52.002, longitude: 5)]
        func feature(_ geometry: [GeoPoint]) throws -> TrafficFeature {
            let object: [String: Any] = ["id": "closed", "sourceId": "test", "kind": "closure", "title": "Closed",
                "geometry": ["encoding": "polyline6", "data": CameraRouteGeometry.encode(geometry)],
                "observedAt": "2026-10-28T12:00:00Z", "matched": true]
            return try JSONDecoder().decode(TrafficFeature.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let closed = try feature(points)
        let endpoints = RoadClosurePresentation.endpoints(for: TrafficDisplayFeature(feature: closed, points: points))
        #expect(endpoints == [points[0], points[2]])
        let point = try feature([points[0]])
        #expect(RoadClosurePresentation.endpoints(for: TrafficDisplayFeature(feature: point, points: [points[0]])) == [points[0]])
    }

    @Test func geometryTimestampsAndSourceCountriesDecodeWithoutCountrySpecificUI() throws {
        let geometry = CameraRouteGeometry.encode([GeoPoint(latitude: 52, longitude: 5), GeoPoint(latitude: 52.001, longitude: 5)])
        let object: [String: Any] = ["sources": [["id": "provider", "countries": ["NL", "BE"], "attribution": "Test", "stale": false]],
            "routingEnabled": false, "truncated": false, "features": [["id": "flow", "sourceId": "provider", "kind": "flow", "title": "Traffic",
                "geometry": ["encoding": "polyline6", "data": geometry], "observedAt": "2026-10-28T12:00:00.125Z", "matched": true, "congestion": "heavy"]]]
        let decoded = try JSONDecoder().decode(TrafficMapResponse.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.sources[0].countries == ["NL", "BE"])
        #expect(decoded.features[0].points.count == 2)
        #expect(!decoded.routingEnabled)
    }
}

private actor ExpiredTrafficTransport: RoutingHTTPTransport {
    private(set) var tokens: [String?] = []
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let object = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        tokens.append(object["token"] as? String)
        let code = tokens.count == 1 ? 410 : 200
        let body = Data(#"{"sources":[],"features":[],"routingEnabled":false,"truncated":false}"#.utf8)
        return (body, HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
    }
}

struct TrafficClientTests {
    @Test func expiredRouteContextFallsBackToViewportTraffic() async throws {
        let transport = ExpiredTrafficTransport()
        let route = try trafficRoute()
        let client = TrafficClient(transport: transport)
        let response = try await client.fetch(bounds: CameraBounds(south: 51, west: 4, north: 53, east: 6),
                                              route: route, endpoint: "https://example.com")
        #expect(response.features.isEmpty)
        let tokens = await transport.tokens
        #expect(tokens.count == 2)
        #expect(tokens[0] == "current")
        #expect(tokens[1] == nil)
    }
}
