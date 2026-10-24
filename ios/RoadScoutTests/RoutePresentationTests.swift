import Foundation
import Testing
@testable import RoadScout

private func namedRoute(_ id: String, seconds: Double, roads: [(String, Double)] = []) throws -> DrivingRoute {
    let maneuvers = roads.isEmpty
        ? [RouteManeuver(id: "depart", instruction: "Drive", spokenInstruction: "Drive", beginIndex: 0, endIndex: 1, seconds: seconds, type: "depart", modifier: "")]
        : roads.enumerated().map { index, road in
            RouteManeuver(id: "\(index)", instruction: "Drive", spokenInstruction: "Drive", beginIndex: 0, endIndex: 1,
                          seconds: seconds / Double(roads.count), type: "continue", modifier: "",
                          streetNames: [road.0], distanceMeters: road.1)
        }
    return try DrivingRoute(geometry: [GeoPoint(latitude: 52, longitude: 5), GeoPoint(latitude: 52.1, longitude: 5.1)],
                            distanceMeters: 15_000, durationSeconds: seconds, maneuvers: maneuvers, id: id)
}

private actor PrototypeWireTransport: RoutingHTTPTransport {
    let data: Data
    private(set) var request: URLRequest?
    init(data: Data) { self.data = data }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        self.request = request
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

struct RoutePresentationTests {
    @Test func meaningfulRoadNamesReplaceNumberedAlternatives() throws {
        let fast = try namedRoute("fast", seconds: 1000, roads: [("A28", 14_000)])
        let local = try namedRoute("local", seconds: 1200, roads: [("N237", 12_000), ("A28", 2_000)])
        let other = try namedRoute("other", seconds: 1500, roads: [("A27", 15_000), ("A1", 14_000), ("A28", 1000)])
        let routes = [fast, local, other]
        #expect(RoutePresentation.title(for: fast, in: routes) == String(localized: "Fastest"))
        #expect(RoutePresentation.title(for: local, in: routes) == String(localized: "Via \("N237")"))
        #expect(RoutePresentation.title(for: other, in: routes) == String(localized: "Via \("A27 · A1")"))
    }

    @Test func firstAlternativeIsOneAndDuplicateCorridorsHaveDistinctNames() throws {
        let routes = try [namedRoute("fast", seconds: 100), namedRoute("one", seconds: 120), namedRoute("two", seconds: 130)]
        #expect(RoutePresentation.title(for: routes[1], in: routes) == String(localized: "Alternative \(1)"))
        #expect(RoutePresentation.title(for: routes[2], in: routes) == String(localized: "Alternative \(2)"))
        let a = try namedRoute("a", seconds: 120, roads: [("A28", 1000)])
        let b = try namedRoute("b", seconds: 130, roads: [("A28", 1000)])
        #expect(RoutePresentation.title(for: a, in: [routes[0], a, b]) != RoutePresentation.title(for: b, in: [routes[0], a, b]))
    }

    @Test(arguments: [50, 85, 100]) func prototypeWireBudgetAndRoadMetadataAreDecoded(budget: Int) async throws {
        let url = try #require(Bundle.main.url(forResource: "route-response", withExtension: "json"))
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var routes = try #require(json["routes"] as? [[String: Any]])
        var legs = try #require(routes[0]["legs"] as? [[String: Any]])
        var maneuvers = try #require(legs[0]["maneuvers"] as? [[String: Any]])
        maneuvers[0]["streetNames"] = ["A28", "Rijksweg 28"]
        maneuvers[0]["distanceMeters"] = 1234
        legs[0]["maneuvers"] = maneuvers; routes[0]["legs"] = legs
        routes[0]["objective"] = "more_corners"
        routes[0]["experiment"] = ["requestedObjective": "more_corners", "effectiveObjective": "more_corners",
            "status": "improved", "method": "candidate_reranking_v1", "baselineDurationSeconds": 25,
            "extraDurationPercent": 12, "detourLimitPercent": budget, "bendCount": 8, "bendsPerKilometer": 2,
            "countrysideShare": 0.7] as [String: Any]
        json["routes"] = routes
        let transport = PrototypeWireTransport(data: try JSONSerialization.data(withJSONObject: json))
        let provider = try RoadScoutRoutingProvider(baseURL: "https://example.com", transport: transport)
        let result = try await provider.routes(for: RouteRequest(origin: .init(latitude: 52, longitude: 5),
            destination: .init(latitude: 52.1, longitude: 5.1), preferences: .init(), objective: .moreCorners, maxExtraDurationPercent: budget))
        let request = try #require(await transport.request)
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["objective"] as? String == "more_corners")
        #expect(body["maxExtraDurationPercent"] as? Int == budget)
        #expect(result[0].maneuvers[0].streetNames == ["A28", "Rijksweg 28"])
        #expect(result[0].maneuvers[0].distanceMeters == 1234)
        #expect(result[0].experiment?.bendCount == 8)
        #expect(RoutePresentation.title(for: result[0], in: result) == String(localized: "More Corners"))
        routes[0]["objective"] = "fastest"
        var experiment = try #require(routes[0]["experiment"] as? [String: Any])
        experiment["effectiveObjective"] = "fastest"; experiment["status"] = "no_improvement"
        routes[0]["experiment"] = experiment; json["routes"] = routes
        let fallback = try RoadScoutRoutingProvider.decode(JSONSerialization.data(withJSONObject: json))
        #expect(fallback[0].experiment?.fallbackMessage != nil)
        #expect(RoutePresentation.title(for: fallback[0], in: fallback) == String(localized: "Fastest"))
    }
}
