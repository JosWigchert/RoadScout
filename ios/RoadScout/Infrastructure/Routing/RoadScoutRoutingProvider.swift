import Foundation

protocol RoutingHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionRoutingTransport: RoutingHTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let session = URLSession(configuration: .ephemeral, delegate: RoutingRedirectPolicy(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              let responseURL = response.url, let requestURL = request.url,
              AppConfiguration.allowsRoutingResponse(responseURL, for: requestURL) else { throw RoutingError.invalidResponse }
        return (data, response)
    }
}

private final class RoutingRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let original = task.originalRequest?.url, let redirected = request.url,
              AppConfiguration.allowsRoutingResponse(redirected, for: original) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

struct RoadScoutRoutingProvider: RoutingProviding {
    let endpoint: URL
    let transport: any RoutingHTTPTransport

    init(baseURL: String, transport: any RoutingHTTPTransport = URLSessionRoutingTransport()) throws {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              AppConfiguration.allowsRoutingURL(url), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw RoutingError.invalidEndpoint
        }
        endpoint = url.appendingPathComponent("v1/routes")
        self.transport = transport
    }

    func routes(for request: RouteRequest) async throws -> [DrivingRoute] {
        guard request.origin.isValid, request.destination.isValid else { throw RoutingError.noRoute }
        var http = URLRequest(url: endpoint, timeoutInterval: 20)
        http.httpMethod = "POST"
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.cachePolicy = .reloadIgnoringLocalCacheData
        let payload = Payload(waypoints: [.init(coordinate: request.origin, headingDegrees: request.originHeading),
                                         .init(coordinate: request.destination, headingDegrees: nil)],
                              preferences: .init(tolls: request.preferences.avoidTolls ? "avoid" : "neutral",
                                                 motorways: request.preferences.avoidHighways ? "avoid" : "neutral"),
                              objective: request.objective.rawValue,
                              maxExtraDurationPercent: request.objective.isExperimental ? request.maxExtraDurationPercent : nil)
        http.httpBody = try JSONEncoder().encode(payload)
        do {
            let (data, response) = try await transport.send(http)
            try Task.checkCancellation()
            guard data.count <= 8_000_000 else { throw RoutingError.invalidResponse }
            guard response.statusCode == 200 else {
                if response.statusCode == 422 { throw RoutingError.noRoute }
                if response.statusCode >= 500 { throw RoutingError.unavailable }
                throw RoutingError.http(response.statusCode)
            }
            return try Self.decode(data)
        } catch is CancellationError { throw CancellationError() }
        catch let error as RoutingError { throw error }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw RoutingError.unavailable }
    }

    private struct Payload: Encodable {
        struct Waypoint: Encodable { let coordinate: GeoPoint; let headingDegrees: Double?; let kind = "stop" }
        struct Preferences: Encodable { let tolls: String; let motorways: String; let ferries = "neutral" }
        let waypoints: [Waypoint]
        let profile = "car"
        let preferences: Preferences
        let objective: String
        let maxExtraDurationPercent: Int?
        let alternatives = 2
        let language = Locale.preferredLanguages.first ?? "en-US"
    }

    static func decode(_ data: Data) throws -> [DrivingRoute] {
        guard data.count <= 8_000_000 else { throw RoutingError.invalidResponse }
        do {
            let response = try JSONDecoder().decode(Response.self, from: data)
            guard !response.routes.isEmpty, response.routes.count <= 3 else { throw RoutingError.invalidResponse }
            return try response.routes.map { try $0.model(attribution: response.attributions.joined(separator: " · ")) }
        } catch { throw RoutingError.invalidResponse }
    }

    private struct Response: Decodable { let routes: [Route]; let attributions: [String] }
    private struct Route: Decodable {
        struct Traffic: Decodable { let value: RouteTrafficMetadata?; init(from decoder: Decoder) { value = try? RouteTrafficMetadata(from: decoder) } }
        struct Summary: Decodable { let distanceMeters: Double; let durationSeconds: Double }
        struct Geometry: Decodable { let encoding: String; let dimensions: Int; let pointCount: Int; let data: String }
        struct Timing: Decodable { let method: String; let anchors: [RouteTimeAnchor] }
        struct Leg: Decodable {
            struct Maneuver: Decodable {
                struct Spoken: Decodable { let before: String?; let alert: String?; let after: String?; let multiCue: Bool? }
                let id: String; let type: String; let modifier: String
                let beginIndex: Int; let endIndex: Int
                let instruction: String; let spoken: Spoken
                let durationSeconds: Double
                let streetNames: [String]?
                let distanceMeters: Double?
            }
            let beginIndex: Int; let endIndex: Int; let maneuvers: [Maneuver]
        }
        let id: String; let summary: Summary; let geometry: Geometry; let legs: [Leg]; let timing: Timing; let language: String
        let objective: String?
        let experiment: RouteExperiment?
        let weatherToken: String?
        let weatherExpiresAt: String?
        let traffic: Traffic?

        func model(attribution: String) throws -> DrivingRoute {
            guard geometry.encoding == "polyline6", geometry.dimensions == 2, !legs.isEmpty,
                  !id.isEmpty, !language.isEmpty else { throw RoutingError.invalidResponse }
            let points = try Polyline6.decode(geometry.data)
            guard points.count == geometry.pointCount, legs.first?.beginIndex == 0,
                  legs.last?.endIndex == points.count - 1,
                  zip(legs, legs.dropFirst()).allSatisfy({ $0.endIndex == $1.beginIndex }),
                  legs.allSatisfy({ $0.beginIndex >= 0 && $0.endIndex >= $0.beginIndex && $0.endIndex < points.count && !$0.maneuvers.isEmpty }) else { throw RoutingError.invalidResponse }
            guard timing.anchors.count >= 2, timing.anchors.first?.geometryIndex == 0,
                  timing.anchors.first?.elapsedSeconds == 0, timing.anchors.last?.geometryIndex == points.count - 1,
                  timing.anchors.allSatisfy({ (0..<points.count).contains($0.geometryIndex) && $0.elapsedSeconds.isFinite && $0.elapsedSeconds >= 0 }),
                  zip(timing.anchors, timing.anchors.dropFirst()).allSatisfy({ $0.geometryIndex <= $1.geometryIndex && $0.elapsedSeconds <= $1.elapsedSeconds }),
                  abs((timing.anchors.last?.elapsedSeconds ?? -1) - summary.durationSeconds) <= 2 else { throw RoutingError.invalidResponse }
            var maneuvers: [RouteManeuver] = []
            for leg in legs {
                for m in leg.maneuvers {
                    guard m.beginIndex >= leg.beginIndex, m.endIndex <= leg.endIndex, !m.instruction.isEmpty else { throw RoutingError.invalidResponse }
                    maneuvers.append(.init(id: m.id, instruction: m.instruction, spokenInstruction: m.spoken.before ?? m.instruction,
                                           beginIndex: m.beginIndex, endIndex: m.endIndex, seconds: m.durationSeconds,
                                           type: m.type, modifier: m.modifier, spokenAlert: m.spoken.alert,
                                           spokenAfter: m.spoken.after, multiCue: m.spoken.multiCue ?? false,
                                           streetNames: m.streetNames ?? [], distanceMeters: m.distanceMeters))
                }
            }
            guard Set(maneuvers.map(\.id)).count == maneuvers.count else { throw RoutingError.invalidResponse }
            return try DrivingRoute(geometry: points, distanceMeters: summary.distanceMeters,
                                    durationSeconds: summary.durationSeconds, maneuvers: maneuvers,
                                    id: id, timing: timing.anchors, language: language, attribution: attribution,
                                    objective: objective.map(RoutePlanningProfile.init(rawValue:)), experiment: experiment,
                                    weatherToken: weatherToken.flatMap { $0.isEmpty ? nil : $0 },
                                    weatherExpiresAt: WeatherWireDate.parse(weatherExpiresAt), traffic: traffic?.value)
        }
    }
}
