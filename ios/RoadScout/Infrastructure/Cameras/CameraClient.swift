import Foundation
import CryptoKit

protocol CameraProviding: Sendable {
    func fetch(bounds: CameraBounds, route: DrivingRoute?, endpoint: String) async throws -> CameraResponse
}

enum CameraClientError: Error { case invalidQuery, invalidResponse, http(Int) }

enum CameraRouteGeometry {
    static func encode(_ points: [GeoPoint]) -> String {
        var result = "", lat = 0, lon = 0
        func append(_ delta: Int) {
            var value = delta < 0 ? ~(delta << 1) : delta << 1
            while value >= 32 {
                result.unicodeScalars.append(UnicodeScalar(((value & 31) | 32) + 63)!)
                value >>= 5
            }
            result.unicodeScalars.append(UnicodeScalar(value + 63)!)
        }
        for point in points {
            let a = Int((point.latitude * 1_000_000).rounded()), b = Int((point.longitude * 1_000_000).rounded())
            append(a - lat); append(b - lon); lat = a; lon = b
        }
        return result
    }
    static func fingerprint(_ route: DrivingRoute?) -> String {
        guard let route else { return "none" }
        // Hash exact doubles, not route IDs or rounded network geometry.
        var data = Data()
        for point in route.geometry {
            for var bits in [point.latitude.bitPattern.bigEndian, point.longitude.bitPattern.bigEndian] {
                withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
            }
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct CameraClient: CameraProviding {
    var transport: any RoutingHTTPTransport = URLSessionRoutingTransport()
    func fetch(bounds: CameraBounds, route: DrivingRoute?, endpoint: String) async throws -> CameraResponse {
        guard bounds.isValid, let base = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              AppConfiguration.allowsRoutingURL(base), base.host != nil, base.user == nil, base.password == nil,
              base.query == nil, base.fragment == nil else { throw CameraClientError.invalidQuery }
        struct RoutePayload: Encodable { let encoding = "polyline6"; let data: String; let corridorMeters = 500 }
        struct Payload: Encodable { let bbox: CameraBounds; let route: RoutePayload? }
        // Never simplify a route: server arclength positions must match NavigationProgress.
        if let route, route.geometry.count > 10_000 || (route.cumulativeMeters.last ?? 0) > 1_000_000 {
            throw CameraClientError.invalidQuery
        }
        let body = try JSONEncoder().encode(Payload(bbox: bounds, route: route.map { RoutePayload(data: CameraRouteGeometry.encode($0.geometry)) }))
        guard body.count <= 256_000 else { throw CameraClientError.invalidQuery }
        var request = URLRequest(url: base.appendingPathComponent("v1/cameras"), timeoutInterval: 20)
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await transport.send(request)
        try Task.checkCancellation()
        guard response.statusCode == 200 else { throw CameraClientError.http(response.statusCode) }
        return try Self.decode(data)
    }
    static func decode(_ data: Data) throws -> CameraResponse {
        guard data.count <= 2_000_000 else { throw CameraClientError.invalidResponse }
        let response = try JSONDecoder().decode(CameraResponse.self, from: data)
        guard response.cameras.count + response.averageSpeedZones.count <= 5000,
              response.cameras.allSatisfy({ $0.coordinate.isValid && ($0.roadGeometry?.allSatisfy(\.isValid) ?? true) }),
              response.averageSpeedZones.allSatisfy({ $0.geometry.allSatisfy(\.isValid) && ($0.start?.isValid ?? true) && ($0.end?.isValid ?? true) })
        else { throw CameraClientError.invalidResponse }
        return response
    }
}
