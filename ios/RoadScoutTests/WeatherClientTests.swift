import Foundation
import Testing
@testable import RoadScout

private actor WeatherWireTransport: RoutingHTTPTransport {
    private(set) var request: URLRequest?
    private var status: Int
    private var body: Data

    init(status: Int = 200, body: Data = Data()) {
        self.status = status
        self.body = body
    }

    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        self.request = request
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private func minimalWeatherData() throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "routeToken": "opaque",
        "generatedAt": "2026-10-24T12:00:05Z",
        "departureAt": "2026-10-24T12:00:00Z",
        "expiresAt": "2026-10-24T12:15:00Z",
        "provider": ["id": "open-meteo", "name": "Open-Meteo", "license": "CC BY 4.0",
                     "attribution": "Weather data by Open-Meteo.com", "coverage": "Worldwide"],
        "recommendation": "roof_down",
        "segments": [],
        "warnings": []
    ])
}

struct WeatherClientTests {
    private let departure = Date(timeIntervalSince1970: 1_792_843_200)

    @Test func postsRouteTokenAndDepartureToTheWeatherEndpoint() async throws {
        let transport = WeatherWireTransport(status: 200, body: try minimalWeatherData())
        let response = try await WeatherClient(transport: transport).fetch(
            routeToken: "opaque", endpoint: "https://example.com", departureAt: departure)
        #expect(response.recommendation == .roofDown)
        #expect(response.routeToken == "opaque")
        let request = try #require(await transport.request)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v1/weather")
        #expect(request.timeoutInterval == 20)
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["routeToken"] as? String == "opaque")
        #expect(json["departureAt"] as? String == WeatherWireDate.string(from: departure))
    }

    @Test func mapsExpiredUnavailableAndHTTPStatuses() async throws {
        let cases: [(Int, WeatherClientError)] = [(410, .expired), (503, .unavailable), (500, .http(500)), (404, .http(404))]
        for (status, expected) in cases {
            do {
                _ = try await WeatherClient(transport: WeatherWireTransport(status: status, body: Data())).fetch(
                    routeToken: "opaque", endpoint: "https://example.com", departureAt: departure)
                Issue.record("expected error for status \(status)")
            } catch let error as WeatherClientError {
                #expect(error == expected)
            }
        }
    }

    @Test func rejectsInvalidEndpointsAndOversizeBodies() async throws {
        do {
            _ = try await WeatherClient(transport: WeatherWireTransport()).fetch(
                routeToken: "opaque", endpoint: "ftp://example.com", departureAt: departure)
            Issue.record("expected invalid endpoint")
        } catch let error as WeatherClientError {
            #expect(error == .invalidEndpoint)
        }

        let oversize = Data(repeating: 0, count: WeatherResponse.maximumResponseBytes + 1)
        do {
            _ = try await WeatherClient(transport: WeatherWireTransport(status: 200, body: oversize)).fetch(
                routeToken: "opaque", endpoint: "https://example.com", departureAt: departure)
            Issue.record("expected invalid response")
        } catch let error as WeatherClientError {
            #expect(error == .invalidResponse)
        }
    }
}
