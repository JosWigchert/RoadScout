import Foundation
import Testing
@testable import RoadScout

private actor WeatherStubClient: WeatherProviding {
    private(set) var requestedTokens: [String] = []
    private var result: Result<WeatherResponse, Error> = .failure(WeatherClientError.unavailable)
    private var delay: Duration = .zero

    func setResult(_ result: Result<WeatherResponse, Error>) { self.result = result }
    func setDelay(_ delay: Duration) { self.delay = delay }

    func fetch(routeToken: String, endpoint: String, departureAt: Date) async throws -> WeatherResponse {
        requestedTokens.append(routeToken)
        if delay != .zero { try await Task.sleep(for: delay) }
        return try result.get()
    }
}

private func weatherRoute(_ token: String) throws -> DrivingRoute {
    try DrivingRoute(geometry: [GeoPoint(latitude: 52, longitude: 5), GeoPoint(latitude: 52.1, longitude: 5.1)],
                     distanceMeters: 13_000, durationSeconds: 900,
                     maneuvers: [RouteManeuver(id: "depart", instruction: "Drive", spokenInstruction: "Drive",
                                               beginIndex: 0, endIndex: 1, seconds: 900, type: "depart", modifier: "straight")],
                     id: "route-\(token)", weatherToken: token)
}

private func weatherTokenlessRoute() throws -> DrivingRoute {
    try DrivingRoute(geometry: [GeoPoint(latitude: 52, longitude: 5), GeoPoint(latitude: 52.1, longitude: 5.1)],
                     distanceMeters: 13_000, durationSeconds: 900,
                     maneuvers: [RouteManeuver(id: "depart", instruction: "Drive", spokenInstruction: "Drive",
                                               beginIndex: 0, endIndex: 1, seconds: 900, type: "depart", modifier: "straight")])
}

private func sampleResponse(_ token: String) -> WeatherResponse {
    WeatherResponse(routeToken: token, recommendation: .roofDown)
}

@MainActor private func awaitWeather(_ predicate: () async -> Bool) async {
    for _ in 0..<500 {
        if await predicate() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
    #expect(await predicate())
}

@MainActor struct WeatherModelTests {
    private let departure = Date(timeIntervalSince1970: 1_792_843_200)

    @Test func loadAllRequestsEveryRouteToken() async throws {
        let client = WeatherStubClient()
        await client.setResult(.success(sampleResponse("opaque")))
        let model = WeatherModel(client: client)
        let routes = [try weatherRoute("a"), try weatherRoute("b"), try weatherRoute("c")]
        model.loadAll(routes: routes, endpoint: "https://example.com", departureAt: departure)
        await awaitWeather { await client.requestedTokens.count == 3 }
        #expect(Set(await client.requestedTokens) == ["a", "b", "c"])
        #expect(model.state(for: routes[0]) == .loaded(sampleResponse("opaque")))
    }

    @Test func routesWithoutTokenAreSkippedAndReturnIdle() async throws {
        let client = WeatherStubClient()
        let model = WeatherModel(client: client)
        let route = try weatherTokenlessRoute()
        model.loadAll(routes: [route], endpoint: "https://example.com", departureAt: departure)
        try await Task.sleep(for: .milliseconds(20))
        #expect(await client.requestedTokens.isEmpty)
        #expect(model.state(for: route) == .idle)
        #expect(model.states.isEmpty)
    }

    @Test func deduplicatesByTokenAndMinuteWithinTTLAndRefetchesAfterExpiry() async throws {
        let client = WeatherStubClient()
        await client.setResult(.success(sampleResponse("a")))
        var now = departure
        let model = WeatherModel(client: client, now: { now })
        let route = try weatherRoute("a")
        model.load(route: route, endpoint: "https://example.com", departureAt: departure)
        await awaitWeather { await client.requestedTokens.count == 1 }
        model.load(route: route, endpoint: "https://example.com", departureAt: departure)
        now = now.addingTimeInterval(300)
        model.load(route: route, endpoint: "https://example.com", departureAt: departure)
        try await Task.sleep(for: .milliseconds(20))
        #expect(await client.requestedTokens.count == 1)
        now = now.addingTimeInterval(901)
        model.load(route: route, endpoint: "https://example.com", departureAt: departure)
        await awaitWeather { await client.requestedTokens.count == 2 }
    }

    @Test func expiredTokenBecomesExpiredStateWithoutRetrying() async throws {
        let client = WeatherStubClient()
        await client.setResult(.failure(WeatherClientError.expired))
        let model = WeatherModel(client: client)
        let route = try weatherRoute("stale")
        model.load(route: route, endpoint: "https://example.com", departureAt: departure)
        await awaitWeather { model.state(for: route) == .expired }
        model.load(route: route, endpoint: "https://example.com", departureAt: departure)
        try await Task.sleep(for: .milliseconds(20))
        #expect(await client.requestedTokens.count == 1)
    }

    @Test func loadedForecastExpiresAtServerDeadlineWithoutAnotherRequest() async throws {
        let client = WeatherStubClient()
        var now = departure
        let response = WeatherResponse(routeToken: "a", expiresAt: departure.addingTimeInterval(30), recommendation: .roofDown)
        await client.setResult(.success(response))
        let model = WeatherModel(client: client, now: { now })
        let route = try weatherRoute("a")
        model.load(route: route, endpoint: "https://example.com", departureAt: departure)
        await awaitWeather { model.state(for: route) == .loaded(response) }
        now = now.addingTimeInterval(30)
        model.expireCachedForecasts()
        #expect(model.state(for: route) == .expired)
        #expect(await client.requestedTokens.count == 1)
    }

    @Test func providerFailureBecomesUnavailableWithMessage() async throws {
        let client = WeatherStubClient()
        await client.setResult(.failure(WeatherClientError.unavailable))
        let model = WeatherModel(client: client)
        let route = try weatherRoute("a")
        model.load(route: route, endpoint: "https://example.com", departureAt: departure)
        await awaitWeather {
            if case .unavailable = model.state(for: route) { return true }
            return false
        }
    }

    @Test func clearCancelsWorkAndResetsStates() async throws {
        let client = WeatherStubClient()
        await client.setDelay(.milliseconds(200))
        await client.setResult(.success(sampleResponse("a")))
        let model = WeatherModel(client: client)
        let route = try weatherRoute("a")
        model.load(route: route, endpoint: "https://example.com", departureAt: departure)
        await awaitWeather { model.state(for: route) == .loading }
        model.clear()
        #expect(model.state(for: route) == .idle)
        #expect(model.states.isEmpty)
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.state(for: route) == .idle)
    }

    @Test func newerRequestSupersedesInFlightOne() async throws {
        let client = WeatherStubClient()
        await client.setDelay(.milliseconds(100))
        await client.setResult(.success(sampleResponse("a")))
        let model = WeatherModel(client: client)
        let route = try weatherRoute("a")
        model.load(route: route, endpoint: "https://example.com", departureAt: departure)
        await awaitWeather { await client.requestedTokens.count == 1 }
        model.load(route: route, endpoint: "https://example.com", departureAt: departure.addingTimeInterval(60))
        await awaitWeather { model.state(for: route) == .loaded(sampleResponse("a")) }
        #expect(await client.requestedTokens.count == 2)
    }
}
