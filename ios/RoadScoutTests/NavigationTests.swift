import Foundation
import Testing
@testable import RoadScout

private func fixtureData() throws -> Data {
    let bundle = Bundle(for: FixtureBundle.self)
    // Fixtures are bundled with the host application, as is the Phase 1 replay.
    let url = Bundle.main.url(forResource: "route-response", withExtension: "json")
        ?? bundle.url(forResource: "route-response", withExtension: "json")
    return try Data(contentsOf: #require(url))
}
private final class FixtureBundle {}
private func fixtureRoute() throws -> DrivingRoute { try #require(RoadScoutRoutingProvider.decode(fixtureData()).first) }
private let epoch = Date(timeIntervalSince1970: 1_000)
private func fix(_ lat: Double = 52.09, _ lon: Double = 5.12, seconds: Double = 0, course: Double = 0) -> LocationFix {
    LocationFix(latitude: lat, longitude: lon, speed: 10, speedAccuracy: 1, horizontalAccuracy: 5,
                course: course, timestamp: epoch.addingTimeInterval(seconds))
}

struct RouteContractTests {
    @Test func sharedFixtureGeometryTimingAndUnknownTypes() throws {
        let route = try fixtureRoute()
        #expect(route.id == "synthetic-route")
        #expect(route.geometry.count == 5)
        #expect(abs(route.geometry[2].latitude - 52.091) < 1e-6)
        #expect(route.maneuvers[1].modifier == "right")
        #expect(abs(route.elapsedSeconds(at: route.cumulativeMeters[2]) - 14) < 0.01)
        var json = try #require(JSONSerialization.jsonObject(with: fixtureData()) as? [String: Any])
        var routes = try #require(json["routes"] as? [[String: Any]])
        var legs = try #require(routes[0]["legs"] as? [[String: Any]])
        var maneuvers = try #require(legs[0]["maneuvers"] as? [[String: Any]])
        maneuvers[1]["type"] = "future_maneuver"
        legs[0]["maneuvers"] = maneuvers; routes[0]["legs"] = legs; json["routes"] = routes
        let decoded = try RoadScoutRoutingProvider.decode(JSONSerialization.data(withJSONObject: json))
        #expect(decoded[0].maneuvers[1].type == "future_maneuver")
    }

    @Test(arguments: ["_", "??", "\u{1}", "~~~~~~~", ""]) func malformedPolylines(_ text: String) {
        #expect(throws: RoutingError.self) { try Polyline6.decode(text) }
    }

    @Test(arguments: ["pointCount", "timing", "indices"]) func malformedContract(_ field: String) throws {
        var json = try #require(JSONSerialization.jsonObject(with: fixtureData()) as? [String: Any])
        var routes = try #require(json["routes"] as? [[String: Any]])
        if field == "pointCount" {
            var geometry = try #require(routes[0]["geometry"] as? [String: Any]); geometry["pointCount"] = 999; routes[0]["geometry"] = geometry
        } else if field == "timing" {
            routes[0]["timing"] = ["method": "maneuver_interpolation", "anchors": [["geometryIndex": 999, "elapsedSeconds": 0]]]
        } else {
            var legs = try #require(routes[0]["legs"] as? [[String: Any]]); legs[0]["endIndex"] = 999; routes[0]["legs"] = legs
        }
        json["routes"] = routes
        let data = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: RoutingError.self) { try RoadScoutRoutingProvider.decode(data) }
    }

    @Test func endpointValidation() throws {
        for endpoint in ["http://192.168.1.111:8080", "https://user:secret@example.com", "https://example.com?token=a", ""] {
            #expect(throws: RoutingError.self) { try RoadScoutRoutingProvider(baseURL: endpoint) }
        }
        #expect(try RoadScoutRoutingProvider(baseURL: "https://routing.example.com").endpoint.path == "/v1/routes")
    }

    @Test func httpRequestAndErrorMapping() async throws {
        let transport = InspectingTransport(data: try fixtureData(), status: 200)
        let provider = try RoadScoutRoutingProvider(baseURL: "https://routing.example.com", transport: transport)
        let routes = try await provider.routes(for: RouteRequest(origin: .init(latitude: 52.09, longitude: 5.12),
                                                                destination: .init(latitude: 52.091, longitude: 5.1216),
                                                                preferences: .init(avoidTolls: true)))
        #expect(routes.count == 1)
        let captured = try #require(await transport.request)
        #expect(captured.httpMethod == "POST")
        let body = try #require(captured.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let preferences = try #require(payload["preferences"] as? [String: String])
        #expect(preferences["tolls"] == "avoid")
        #expect(payload["profile"] as? String == "car")
        for (status, expected) in [(422, RoutingError.noRoute), (503, .unavailable), (400, .http(400))] {
            let service = try RoadScoutRoutingProvider(baseURL: "https://routing.example.com", transport: InspectingTransport(data: Data(), status: status))
            do {
                _ = try await service.routes(for: RouteRequest(origin: .init(latitude: 0, longitude: 0), destination: .init(latitude: 1, longitude: 1), preferences: .init()))
                Issue.record("Expected HTTP error")
            } catch { #expect(error as? RoutingError == expected) }
        }
    }
}

private actor InspectingTransport: RoutingHTTPTransport {
    let data: Data; let status: Int
    private(set) var request: URLRequest?
    init(data: Data, status: Int) { self.data = data; self.status = status }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        self.request = request
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

struct NavigationTrackerTests {
    @Test func sustainedWrongDirectionTriggersReroute() throws {
        var tracker = NavigationTracker(route: try fixtureRoute())
        _ = tracker.update(fix(), at: epoch)
        for seconds in [1.0, 4.0] {
            let sample = fix(52.0901, seconds: seconds, course: 180)
            let value = tracker.update(sample, at: sample.timestamp)
            #expect(value?.offRoute == (seconds == 4))
        }
    }

    @Test func signalGapDoesNotCountAsOffRouteEvidence() throws {
        var tracker = NavigationTracker(route: try fixtureRoute())
        _ = tracker.update(fix(), at: epoch)
        let first = fix(52.095, seconds: 1)
        _ = tracker.update(first, at: first.timestamp)
        let afterGap = fix(52.095, seconds: 20)
        #expect(tracker.update(afterGap, at: afterGap.timestamp)?.offRoute == false)
    }
    @Test func progressAndArrival() throws {
        let route = try fixtureRoute(); var tracker = NavigationTracker(route: route)
        let firstValue = tracker.update(fix(), at: epoch)
        let first = try #require(firstValue)
        #expect(first.maneuverIndex == 1)
        #expect(first.remainingMeters > 210)
        let middleValue = tracker.update(fix(52.0905, seconds: 1), at: epoch.addingTimeInterval(1))
        let middle = try #require(middleValue)
        #expect(middle.remainingMeters < first.remainingMeters)
        let end = fix(52.091, 5.1216, seconds: 2, course: 90)
        #expect(tracker.update(end, at: end.timestamp)?.arrived == false)
        let final = fix(52.091, 5.1216, seconds: 3, course: 90)
        #expect(tracker.update(final, at: final.timestamp)?.arrived == true)
    }

    @Test func jitterDoesNotReverseProgress() throws {
        var tracker = NavigationTracker(route: try fixtureRoute())
        let forward = fix(52.0905, seconds: 1)
        let aValue = tracker.update(forward, at: forward.timestamp)
        let a = try #require(aValue)
        let backward = fix(52.09048, seconds: 2)
        let bValue = tracker.update(backward, at: backward.timestamp)
        let b = try #require(bValue)
        #expect(b.traveledMeters >= a.traveledMeters)
        #expect(!b.offRoute)
    }

    @Test func offRouteRequiresSustainedEvidenceAndRecovers() throws {
        var tracker = NavigationTracker(route: try fixtureRoute())
        _ = tracker.update(fix(), at: epoch)
        for seconds in [1.0, 2.0, 3.0, 4.0] {
            let p = fix(52.095, 5.12, seconds: seconds)
            let value = tracker.update(p, at: p.timestamp)
            let state = try #require(value)
            #expect(state.offRoute == (seconds >= 4))
        }
        let recovered = fix(52.0905, seconds: 5)
        #expect(tracker.update(recovered, at: recovered.timestamp)?.offRoute == false)
    }

    @Test func staleInvalidAndOutOfOrderFixesIgnored() throws {
        var tracker = NavigationTracker(route: try fixtureRoute())
        #expect(tracker.update(fix(), at: epoch.addingTimeInterval(6)) == nil)
        var invalid = fix(); invalid.horizontalAccuracy = 100
        #expect(tracker.update(invalid, at: epoch) == nil)
        #expect(tracker.update(fix(seconds: 2), at: epoch.addingTimeInterval(2)) != nil)
        #expect(tracker.update(fix(seconds: 1), at: epoch.addingTimeInterval(2)) == nil)
    }
}

@MainActor private final class TestAudio: AudioAnnouncing {
    var texts: [String] = []
    func speak(_ text: String, language: String) { texts.append(text) }
    func stop() {}
}
@MainActor private final class Clock { var date = epoch }
private actor TestRouter: RoutingProviding {
    private(set) var calls = 0
    private(set) var requests: [RouteRequest] = []
    var pending: [CheckedContinuation<[DrivingRoute], Error>] = []
    let failure: Bool
    init(failure: Bool = false) { self.failure = failure }
    func routes(for request: RouteRequest) async throws -> [DrivingRoute] {
        calls += 1
        requests.append(request)
        if failure { throw RoutingError.unavailable }
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func finish(_ routes: [DrivingRoute]) { let values = pending; pending = []; for value in values { value.resume(returning: routes) } }
}
@MainActor private func settle(_ predicate: () -> Bool) async {
    for _ in 0..<500 { if predicate() { return }; try? await Task.sleep(for: .milliseconds(1)) }
    #expect(predicate())
}

@MainActor struct NavigationModelTests {
    @Test func successfulRerouteReplacesGeometryAndContinues() async throws {
        let router = TestRouter(), clock = Clock()
        let model = NavigationModel(audio: TestAudio(), provider: { _ in router }, now: { clock.date })
        try model.loadDemo(); model.start(fix: fix())
        for seconds in [1.0, 4.0] {
            clock.date = epoch.addingTimeInterval(seconds); model.consume(fix(52.095, seconds: seconds))
        }
        for _ in 0..<100 { if await router.calls > 0 { break }; await Task.yield() }
        let original = try fixtureRoute()
        let replacement = try DrivingRoute(geometry: original.geometry, distanceMeters: original.distanceMeters,
                                            durationSeconds: original.durationSeconds, maneuvers: original.maneuvers,
                                            id: "rerouted", timing: original.timing)
        await router.finish([replacement, original])
        await settle { !model.isLoading }
        #expect(model.selectedRoute?.id == "rerouted")
        #expect(model.routes.count == 2)
        #expect(model.isNavigating)
        clock.date = epoch.addingTimeInterval(5); model.consume(fix(52.0905, seconds: 5))
        #expect(model.progress?.offRoute == false)
        #expect(model.progress?.remainingMeters ?? 0 > 0)
    }
    @Test func returnToOriginalRouteCancelsPendingReroute() async throws {
        let router = TestRouter(), clock = Clock()
        let model = NavigationModel(audio: TestAudio(), provider: { _ in router }, now: { clock.date })
        try model.loadDemo(); model.start(fix: fix())
        let original = model.selectedRoute?.id
        for seconds in [1.0, 4.0] {
            clock.date = epoch.addingTimeInterval(seconds)
            model.consume(fix(52.095, seconds: seconds))
        }
        for _ in 0..<100 { if await router.calls > 0 { break }; await Task.yield() }
        #expect(model.isLoading)
        clock.date = epoch.addingTimeInterval(5)
        model.consume(fix(52.0905, seconds: 5))
        #expect(!model.isLoading)
        let route = try fixtureRoute()
        let obsolete = try DrivingRoute(geometry: route.geometry, distanceMeters: route.distanceMeters,
            durationSeconds: route.durationSeconds, maneuvers: route.maneuvers, id: "obsolete")
        await router.finish([obsolete])
        for _ in 0..<20 { await Task.yield() }
        #expect(model.selectedRoute?.id == original)
        #expect(model.isNavigating)
    }

    @Test func signalGapOutsideRouteDoesNotCancelPendingReroute() async throws {
        let router = TestRouter(), clock = Clock()
        let model = NavigationModel(audio: TestAudio(), provider: { _ in router }, now: { clock.date })
        try model.loadDemo(); model.start(fix: fix())
        for seconds in [1.0, 4.0] {
            clock.date = epoch.addingTimeInterval(seconds)
            model.consume(fix(52.095, seconds: seconds))
        }
        for _ in 0..<100 { if await router.calls > 0 { break }; await Task.yield() }
        clock.date = epoch.addingTimeInterval(20)
        model.consume(fix(52.095, seconds: 20))
        #expect(model.progress?.offRoute == false) // Hysteresis restarts after a gap.
        #expect(model.progress?.onRoute == false)
        #expect(model.isLoading)
        model.end()
        await router.finish([try fixtureRoute()])
    }

    @Test func rerouteRetainsObjectiveBudgetPreferencesAndActualOrigin() async throws {
        let router = TestRouter(), clock = Clock()
        let model = NavigationModel(audio: TestAudio(), provider: { _ in router }, now: { clock.date })
        model.preview(Destination(name: "Test", point: .init(latitude: 52.091, longitude: 5.1216)),
            fix: fix(), endpoint: "https://example.com", preferences: .init(avoidTolls: true, avoidHighways: true),
            objective: .moreCorners, maxExtraDurationPercent: 50)
        for _ in 0..<100 { if await router.calls > 0 { break }; await Task.yield() }
        await router.finish([try fixtureRoute()])
        await settle { !model.isLoading }
        model.start(fix: fix())
        for seconds in [1.0, 4.0] {
            clock.date = epoch.addingTimeInterval(seconds)
            model.consume(fix(52.095, seconds: seconds, course: 90))
        }
        for _ in 0..<100 { if await router.calls == 2 { break }; await Task.yield() }
        let request = try #require(await router.requests.last)
        #expect(request.objective == .moreCorners)
        #expect(request.maxExtraDurationPercent == 50)
        #expect(request.preferences.avoidTolls)
        #expect(request.preferences.avoidHighways)
        #expect(request.origin.latitude == 52.095)
        #expect(request.originHeading != nil)
        model.end()
        await router.finish([try fixtureRoute()])
        for _ in 0..<20 { await Task.yield() }
        #expect(model.selectedRoute == nil)
    }
    @Test func muteDedupPauseAndResume() throws {
        let clock = Clock(), audio = TestAudio()
        let model = NavigationModel(audio: audio, now: { clock.date })
        try model.loadDemo(); model.start(fix: fix())
        clock.date = epoch.addingTimeInterval(1); model.consume(fix(52.0905, seconds: 1))
        let count = audio.texts.count
        clock.date = epoch.addingTimeInterval(2); model.consume(fix(52.0906, seconds: 2))
        #expect(audio.texts.count == count)
        model.pause(); #expect(model.isPaused)
        clock.date = epoch.addingTimeInterval(10); model.start(fix: fix(seconds: 2))
        #expect(model.isPaused)
        model.muted = true; model.start(fix: fix(52.0907, seconds: 10))
        #expect(!model.isPaused)
        #expect(audio.texts.count == count)
        model.end(); #expect(model.selectedRoute == nil)
    }

    @Test func outageRetainsRouteAndThrottlesReroutes() async throws {
        let clock = Clock(), audio = TestAudio(), router = TestRouter(failure: true)
        let model = NavigationModel(audio: audio, provider: { _ in router }, now: { clock.date })
        // Preview through the real coordinator first, then load the fixture to exercise outage handling.
        model.preview(Destination(name: "Test", point: .init(latitude: 52.091, longitude: 5.1216)), fix: fix(), endpoint: "https://example.com", preferences: .init())
        await settle { !model.isLoading }
        try model.loadDemo(); model.start(fix: fix())
        let original = model.selectedRoute?.id
        for second in [1.0, 4.0] {
            clock.date = epoch.addingTimeInterval(second); model.consume(fix(52.095, seconds: second))
        }
        await settle { !model.isLoading }
        #expect(model.selectedRoute?.id == original)
        #expect(model.progress?.offRoute == true)
        let calls = await router.calls
        for second in 5...20 { clock.date = epoch.addingTimeInterval(Double(second)); model.consume(fix(52.095, seconds: Double(second))) }
        #expect(await router.calls == calls)
        #expect(model.isNavigating)
    }

    @Test func cancelledPreviewCannotResurrectRoute() async throws {
        let router = TestRouter(), clock = Clock()
        let model = NavigationModel(audio: TestAudio(), provider: { _ in router }, now: { clock.date })
        model.preview(Destination(name: "Test", point: .init(latitude: 52.091, longitude: 5.1216)), fix: fix(), endpoint: "https://example.com", preferences: .init())
        for _ in 0..<100 { if await router.calls > 0 { break }; await Task.yield() }
        #expect(await router.calls == 1)
        model.end()
        await router.finish([try fixtureRoute()])
        for _ in 0..<20 { await Task.yield() }
        #expect(model.selectedRoute == nil)
        #expect(!model.isLoading)
    }
}

@MainActor private final class TestSearch: PlaceSearching {
    var pending: [CheckedContinuation<[Destination], Error>] = []
    func search(_ query: String, near: GeoPoint?) async throws -> [Destination] {
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
}

@MainActor struct PlaceSearchTests {
    @Test func oldSearchCannotOverwriteNewResults() async {
        let service = TestSearch()
        let controlled = PlaceSearchModel(service: service)
        controlled.query = "old"; controlled.search(near: nil)
        await settle { service.pending.count == 1 }
        controlled.query = "new"; controlled.search(near: nil)
        await settle { service.pending.count == 2 }
        let old = Destination(name: "old", point: .init(latitude: 0, longitude: 0))
        let new = Destination(name: "new", point: .init(latitude: 1, longitude: 1))
        service.pending[1].resume(returning: [new])
        await settle { !controlled.isLoading }
        service.pending[0].resume(returning: [old])
        for _ in 0..<20 { await Task.yield() }
        #expect(controlled.results.map(\.name) == ["new"])
        controlled.query = "  "; controlled.search(near: nil)
        #expect(!controlled.isLoading)
    }
}
