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
