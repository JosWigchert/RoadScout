import Foundation

protocol WeatherProviding: Sendable {
    func fetch(routeToken: String, endpoint: String, departureAt: Date) async throws -> WeatherResponse
}

enum WeatherClientError: Error, LocalizedError, Equatable, Sendable {
    case invalidEndpoint
    case invalidResponse
    case expired
    case unavailable
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: String(localized: "Set a supported RoadScout API base URL in Settings.")
        case .invalidResponse: String(localized: "The weather service returned an unusable forecast.")
        case .expired: String(localized: "Weather expired — recalculate.")
        case .unavailable: String(localized: "Weather unavailable.")
        case .http(let code): String(localized: "Weather service returned HTTP \(code).")
        }
    }
}

/// Single `POST /v1/weather` client. Reuses the routing transport so endpoint
/// validation, redirect policy and cancellation behave exactly like routing.
struct WeatherClient: WeatherProviding {
    var transport: any RoutingHTTPTransport = URLSessionRoutingTransport()

    func fetch(routeToken: String, endpoint: String, departureAt: Date) async throws -> WeatherResponse {
        let token = routeToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw WeatherClientError.invalidEndpoint }
        guard let base = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              AppConfiguration.allowsRoutingURL(base), let host = base.host, !host.isEmpty,
              base.user == nil, base.password == nil, base.query == nil, base.fragment == nil else {
            throw WeatherClientError.invalidEndpoint
        }
        struct Payload: Encodable { let routeToken: String; let departureAt: String }
        let body = try JSONEncoder().encode(Payload(routeToken: token, departureAt: WeatherWireDate.string(from: departureAt)))
        var request = URLRequest(url: base.appendingPathComponent("v1/weather"), timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await transport.send(request)
            try Task.checkCancellation()
            guard data.count <= WeatherResponse.maximumResponseBytes else { throw WeatherClientError.invalidResponse }
            switch response.statusCode {
            case 200: return try WeatherResponse.decode(data)
            case 410: throw WeatherClientError.expired
            case 503: throw WeatherClientError.unavailable
            default: throw WeatherClientError.http(response.statusCode)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as WeatherClientError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw WeatherClientError.unavailable
        }
    }
}
