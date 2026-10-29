import Foundation

enum TrafficClientError: Error { case invalidEndpoint, invalidResponse, expired, unavailable }
protocol TrafficProviding: Sendable {
    func fetch(bounds: CameraBounds, route: DrivingRoute?, endpoint: String) async throws -> TrafficMapResponse
    func refresh(route: DrivingRoute, fix: LocationFix, traveledMeters: Double, checkAlternatives: Bool, endpoint: String) async throws -> TrafficRefresh
}

struct TrafficClient: TrafficProviding {
    var transport: any RoutingHTTPTransport = URLSessionRoutingTransport()
    private func send<T: Encodable>(_ body: T, path: String, endpoint: String) async throws -> Data {
        guard let base = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              AppConfiguration.allowsRoutingURL(base), base.host != nil, base.user == nil, base.password == nil,
              base.query == nil, base.fragment == nil else { throw TrafficClientError.invalidEndpoint }
        var request = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: 20)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body); request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await transport.send(request)
        try Task.checkCancellation()
        guard data.count <= 8_000_000 else { throw TrafficClientError.invalidResponse }
        if response.statusCode == 410 { throw TrafficClientError.expired }
        guard response.statusCode == 200 else { throw TrafficClientError.unavailable }
        return data
    }
    func fetch(bounds: CameraBounds, route: DrivingRoute?, endpoint: String) async throws -> TrafficMapResponse {
        struct Shape: Encodable { let encoding = "polyline6"; let data: String; let corridorMeters = 150.0 }
        struct Body: Encodable { let bbox: CameraBounds; let route: Shape?; let token: String? }
        let token = route?.traffic?.token
        let shape = token == nil ? route.map { Shape(data: CameraRouteGeometry.encode($0.geometry)) } : nil
        let data: Data
        do {
            data = try await send(Body(bbox: bounds, route: shape, token: token), path: "v1/traffic", endpoint: endpoint)
        } catch TrafficClientError.expired {
            // A long trip or server restart can expire the optional route context.
            // Viewport traffic must still work without a route token.
            data = try await send(Body(bbox: bounds, route: nil, token: nil), path: "v1/traffic", endpoint: endpoint)
        }
        let response = try JSONDecoder().decode(TrafficMapResponse.self, from: data)
        guard response.features.count <= 1500 else { throw TrafficClientError.invalidResponse }
        return response
    }
    func refresh(route: DrivingRoute, fix: LocationFix, traveledMeters: Double, checkAlternatives: Bool, endpoint: String) async throws -> TrafficRefresh {
        guard let token = route.traffic?.token, !token.isEmpty else { throw TrafficClientError.expired }
        struct Body: Encodable {
            let token: String; let position: GeoPoint; let heading: Double?; let speedMps: Double
            let at: String; let traveledMeters: Double; let checkAlternatives: Bool
        }
        let data = try await send(Body(token: token, position: GeoPoint(latitude: fix.latitude, longitude: fix.longitude),
            heading: fix.course.isFinite && (0..<360).contains(fix.course) ? fix.course : nil,
            speedMps: fix.speed.isFinite ? max(0, fix.speed) : 0, at: WeatherWireDate.string(from: fix.timestamp),
            traveledMeters: traveledMeters, checkAlternatives: checkAlternatives), path: "v1/traffic/route", endpoint: endpoint)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TrafficClientError.invalidResponse }
        let expiry = WeatherWireDate.parse(object["expiresAt"] as? String)
        let live = object["routingEnabled"] as? Bool == true
        let seconds = object["remainingSeconds"] as? Double
        var routes: [DrivingRoute] = []
        if let alternatives = object["alternatives"] as? [String: Any] {
            routes = try RoadScoutRoutingProvider.decode(JSONSerialization.data(withJSONObject: alternatives))
        }
        guard !live || (expiry != nil && seconds?.isFinite == true && (seconds ?? -1) >= 0) else { throw TrafficClientError.invalidResponse }
        return TrafficRefresh(routingEnabled: live, remainingSeconds: seconds, expiresAt: expiry, alternatives: routes)
    }
}
