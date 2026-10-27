import Foundation
import Testing
@testable import RoadScout

private actor CameraMemoryCache: CameraCaching {
    var entries: [CameraCacheEntry] = []
    func load(scope: CameraCacheScope) -> CameraCacheEntry? { entries.first { $0.scope == scope } }
    func save(_ entry: CameraCacheEntry) { entries.append(entry) }
}
private actor CameraStubClient: CameraProviding {
    var calls = 0
    var fails = false
    func setFailure() { fails = true }
    func fetch(bounds: CameraBounds, route: DrivingRoute?, endpoint: String) throws -> CameraResponse {
        calls += 1
        if fails { throw URLError(.notConnectedToInternet) }
        return .init(dataset: .init(version: "fixture", coverage: "NL", stale: false),
                     cameras: [], averageSpeedZones: [], truncated: false)
    }
}
private actor CameraWireTransport: RoutingHTTPTransport {
    var request: URLRequest?
    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        self.request = request
        let data = try JSONEncoder().encode(CameraResponse(dataset: .init(coverage: "NL"), cameras: [], averageSpeedZones: [], truncated: false))
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

struct CameraModelTests {
    let bounds = CameraBounds(south: 51.9, west: 4.9, north: 52.1, east: 5.1)
    @Test @MainActor func debounceThrottleCacheAndEndpointIsolation() async throws {
        let client = CameraStubClient(), cache = CameraMemoryCache()
        var now = Date()
        let model = CameraAlertModel(client: client, cache: cache, now: { now }, debounce: .milliseconds(1))
        model.fetch(bounds: bounds, route: nil, endpoint: "https://example.com")
        model.fetch(bounds: bounds, route: nil, endpoint: "https://example.com")
        try await Task.sleep(for: .milliseconds(500))
        #expect(await client.calls == 1)
        #expect(model.metadata?.version == "fixture")
        #expect(model.isUsingCache == false)
        model.fetch(bounds: bounds, route: nil, endpoint: "https://example.com")
        #expect(await client.calls == 1)
        await client.setFailure(); now = now.addingTimeInterval(31)
        model.fetch(bounds: bounds, route: nil, endpoint: "https://example.com")
        try await Task.sleep(for: .milliseconds(500))
        #expect(model.isUsingCache)
        #expect(model.cachedBounds == bounds)
        #expect(model.statusMessage?.contains("Cached query area only") == true)
        model.fetch(bounds: bounds, route: nil, endpoint: "https://other.example")
        #expect(model.metadata == nil)
        try await Task.sleep(for: .milliseconds(500))
        #expect(model.metadata == nil)
        #expect(model.isUsingCache == false)
        #expect(model.statusMessage?.contains("No cached data") == true)
        model.clear()
    }
    @Test @MainActor func clearCancelsDebouncedRequest() async throws {
        let client = CameraStubClient()
        let model = CameraAlertModel(client: client, cache: CameraMemoryCache())
        model.fetch(bounds: bounds, route: nil, endpoint: "https://example.com")
        model.clear()
        try await Task.sleep(for: .milliseconds(400))
        #expect(await client.calls == 0)
        #expect(model.metadata == nil)
    }
    @Test func oneGoPOSTWithPolylineRoute() async throws {
        let geometry = [GeoPoint(latitude: 52, longitude: 5), GeoPoint(latitude: 52.001, longitude: 5.002)]
        let route = try DrivingRoute(geometry: geometry, distanceMeters: 200, durationSeconds: 20,
                                     maneuvers: [.init(id: "m", instruction: "Go", spokenInstruction: "Go", beginIndex: 0, endIndex: 1, seconds: 20, type: "start", modifier: "")])
        let transport = CameraWireTransport()
        _ = try await CameraClient(transport: transport).fetch(bounds: bounds, route: route, endpoint: "https://example.com")
        let request = try #require(await transport.request)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v1/cameras")
        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let payload = try #require(object["route"] as? [String: Any])
        #expect(payload["encoding"] as? String == "polyline6")
        #expect(try Polyline6.decode(#require(payload["data"] as? String)) == geometry)
        let changed = try DrivingRoute(geometry: [geometry[0], .init(latitude: 52.002, longitude: 5.002)], distanceMeters: 200,
                                      durationSeconds: 20, maneuvers: route.maneuvers, id: route.id)
        #expect(CameraRouteGeometry.fingerprint(changed) != CameraRouteGeometry.fingerprint(route))
    }
}
