import Foundation
import Testing
@testable import RoadScout

private let weatherGeometry = [GeoPoint(latitude: 52.1, longitude: 5.3), GeoPoint(latitude: 52.11, longitude: 5.31)]

private func weatherResponseJSON(points: [GeoPoint] = weatherGeometry, recommendation: String = "rain_risk") -> [String: Any] {
    [
        "routeToken": "opaque",
        "generatedAt": "2026-10-24T12:00:05.250Z",
        "departureAt": "2026-10-24T12:00:00Z",
        "expiresAt": "2026-10-24T12:15:00Z",
        "provider": ["id": "open-meteo", "name": "Open-Meteo", "license": "CC BY 4.0",
                     "attribution": "Weather data by Open-Meteo.com",
                     "coverage": "Worldwide; 15-minute precipitation in the Netherlands/Central Europe"],
        "recommendation": recommendation,
        "summary": ["maxProbabilityPercent": 70, "maxIntensityMmPerHour": 0.8,
                    "worstAt": "2026-10-24T14:20:00Z",
                    "worstCoordinate": ["latitude": 52.1, "longitude": 5.3],
                    "sampleCount": 40, "rainRiskSampleCount": 5],
        "segments": [[
            "startMeters": 12_000, "endMeters": 16_000,
            "startAt": "2026-10-24T14:10:00.500Z", "endAt": "2026-10-24T14:30:00Z",
            "probabilityPercent": 70, "intensityMmPerHour": 0.8,
            "geometry": ["encoding": "polyline6", "data": CameraRouteGeometry.encode(points)]
        ]],
        "warnings": [["code": "partial_coverage", "message": "coverage gap"]]
    ]
}

struct WeatherDecodingTests {
    @Test func decodesResponseWithSegmentGeometryAndTimestamps() throws {
        let data = try JSONSerialization.data(withJSONObject: weatherResponseJSON())
        let response = try WeatherResponse.decode(data)
        #expect(response.routeToken == "opaque")
        #expect(response.recommendation == .rainRisk)
        #expect(response.provider.id == "open-meteo")
        #expect(response.provider.attribution == "Weather data by Open-Meteo.com")
        #expect(response.generatedAt == Date(timeIntervalSince1970: 1792843205.25))
        #expect(response.departureAt == Date(timeIntervalSince1970: 1792843200))
        #expect(response.expiresAt == Date(timeIntervalSince1970: 1792844100))
        let summary = try #require(response.summary)
        #expect(summary.maxProbabilityPercent == 70)
        #expect(summary.maxIntensityMmPerHour == 0.8)
        #expect(summary.sampleCount == 40)
        #expect(summary.rainRiskSampleCount == 5)
        #expect(summary.worstAt == Date(timeIntervalSince1970: 1792851600))
        #expect(summary.worstCoordinate == GeoPoint(latitude: 52.1, longitude: 5.3))
        let segment = try #require(response.segments.first)
        #expect(segment.startMeters == 12_000)
        #expect(segment.endMeters == 16_000)
        #expect(segment.startAt == Date(timeIntervalSince1970: 1792851000.5))
        #expect(segment.endAt == Date(timeIntervalSince1970: 1792852200))
        #expect(segment.probabilityPercent == 70)
        #expect(segment.intensityMmPerHour == 0.8)
        #expect(segment.geometry == weatherGeometry)
        #expect(response.warnings.first?.code == "partial_coverage")
    }

    @Test func missingSummaryAndSegmentsStayOptionalAndUnknownRecommendationFallsBack() throws {
        var json: [String: Any] = ["routeToken": "opaque", "recommendation": "sunny_side_up"]
        json["summary"] = NSNull()
        json["segments"] = NSNull()
        let response = try WeatherResponse.decode(JSONSerialization.data(withJSONObject: json))
        #expect(response.summary == nil)
        #expect(response.segments.isEmpty)
        #expect(response.warnings.isEmpty)
        #expect(response.recommendation == .unavailable)
        #expect(response.provider == WeatherProviderInfo())
    }

    @Test func dryRouteDecodesRoofDownWithoutSegments() throws {
        var json = weatherResponseJSON(recommendation: "roof_down")
        json["segments"] = []
        json["summary"] = NSNull()
        let response = try WeatherResponse.decode(JSONSerialization.data(withJSONObject: json))
        #expect(response.recommendation == .roofDown)
        #expect(response.summary == nil)
        #expect(response.segments.isEmpty)
    }

    @Test(arguments: ["polyline5", "geojson"]) func invalidSegmentGeometryIsRejected(encoding: String) throws {
        var json = weatherResponseJSON()
        var segments = try #require(json["segments"] as? [[String: Any]])
        segments[0]["geometry"] = ["encoding": encoding, "data": ""]
        json["segments"] = segments
        #expect(throws: WeatherClientError.self) {
            try WeatherResponse.decode(JSONSerialization.data(withJSONObject: json))
        }
    }

    @Test func malformedSegmentBoundsAreRejected() throws {
        var json = weatherResponseJSON()
        var segments = try #require(json["segments"] as? [[String: Any]])
        segments[0]["endMeters"] = 1_000
        segments[0]["startMeters"] = 5_000
        json["segments"] = segments
        #expect(throws: WeatherClientError.self) {
            try WeatherResponse.decode(JSONSerialization.data(withJSONObject: json))
        }
    }

    @Test func oversizeResponseIsRejected() {
        let data = Data(repeating: 0, count: WeatherResponse.maximumResponseBytes + 1)
        #expect(throws: WeatherClientError.self) { try WeatherResponse.decode(data) }
    }
}

struct WeatherRouteTokenDecodingTests {
    private func routeFixtureData() throws -> Data {
        let bundle = Bundle(for: WeatherFixtureBundle.self)
        let url = Bundle.main.url(forResource: "route-response", withExtension: "json")
            ?? bundle.url(forResource: "route-response", withExtension: "json")
        return try Data(contentsOf: #require(url))
    }

    @Test func routesDecodeWeatherTokenAndExpiry() throws {
        var json = try #require(JSONSerialization.jsonObject(with: routeFixtureData()) as? [String: Any])
        var routes = try #require(json["routes"] as? [[String: Any]])
        routes[0]["weatherToken"] = "route-token-42"
        routes[0]["weatherExpiresAt"] = "2026-10-24T12:15:00Z"
        json["routes"] = routes
        let decoded = try RoadScoutRoutingProvider.decode(JSONSerialization.data(withJSONObject: json))
        #expect(decoded[0].weatherToken == "route-token-42")
        #expect(decoded[0].weatherExpiresAt == Date(timeIntervalSince1970: 1792844100))
    }

    @Test func routesWithoutWeatherFieldsKeepNilDefaults() throws {
        let route = try #require(RoadScoutRoutingProvider.decode(try routeFixtureData()).first)
        #expect(route.weatherToken == nil)
        #expect(route.weatherExpiresAt == nil)
    }

    @Test func fractionalWeatherExpiryIsTolerated() throws {
        var json = try #require(JSONSerialization.jsonObject(with: routeFixtureData()) as? [String: Any])
        var routes = try #require(json["routes"] as? [[String: Any]])
        routes[0]["weatherToken"] = "route-token-42"
        routes[0]["weatherExpiresAt"] = "2026-10-24T12:15:00.123Z"
        json["routes"] = routes
        let decoded = try RoadScoutRoutingProvider.decode(JSONSerialization.data(withJSONObject: json))
        #expect(decoded[0].weatherExpiresAt == Date(timeIntervalSince1970: 1792844100.123))
    }
}

private final class WeatherFixtureBundle {}
