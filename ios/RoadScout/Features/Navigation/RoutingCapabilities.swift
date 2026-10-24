import Foundation
import Observation

/// A routing style advertised by the server. Titles, experimental status and
/// detour budgets come from Go so new styles do not require an app update.
struct RouteOption: Identifiable, Equatable, Sendable {
    static let defaultDetourOptions = [15, 30, 50, 85, 100]

    let id: String
    let title: String
    let isExperimental: Bool
    let detourOptions: [Int]

    init(id: String, title: String? = nil, isExperimental: Bool? = nil, detourOptions: [Int] = []) {
        self.id = id
        let supplied = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = (supplied?.isEmpty == false) ? supplied! : Self.defaultTitle(id)
        let experimental = isExperimental ?? (id != "fastest")
        self.isExperimental = experimental
        let allowed = detourOptions.filter { (0...100).contains($0) }
        let unique = Array(Set(allowed)).sorted()
        self.detourOptions = unique.isEmpty && experimental ? Self.defaultDetourOptions : unique
    }

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String, !id.isEmpty else { return nil }
        self.init(id: id, title: json["title"] as? String,
                  isExperimental: json["experimental"] as? Bool ?? (id != "fastest"),
                  detourOptions: json["detourOptions"] as? [Int] ?? [])
    }

    var profile: RoutePlanningProfile { RoutePlanningProfile(rawValue: id) }

    static let fastest = RouteOption(id: "fastest")

    static func defaultTitle(_ id: String) -> String {
        switch id {
        case "fastest": String(localized: "Fastest")
        case "scenic": String(localized: "Scenic")
        case "more_corners": String(localized: "More Corners")
        default: id.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

struct RoutingCapabilities: Sendable {
    let routingOptions: [RouteOption]
    let detourOptions: [Int]

    static func decode(_ data: Data) throws -> RoutingCapabilities {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RoutingError.invalidResponse
        }
        var options = (object["routingOptions"] as? [[String: Any]] ?? []).compactMap(RouteOption.init(json:))
        if options.isEmpty, let objectives = object["objectives"] as? [String] {
            options = objectives.map { RouteOption(id: $0) }
        }
        if !options.contains(where: { $0.id == "fastest" }) { options.insert(.fastest, at: 0) }
        return RoutingCapabilities(routingOptions: options, detourOptions: object["detourOptions"] as? [Int] ?? [])
    }
}

struct RoutingCapabilitiesClient: Sendable {
    let transport: any RoutingHTTPTransport

    init(transport: any RoutingHTTPTransport = URLSessionRoutingTransport()) {
        self.transport = transport
    }

    func fetch(baseURL: String) async throws -> RoutingCapabilities {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              AppConfiguration.allowsRoutingURL(url), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw RoutingError.invalidEndpoint
        }
        var request = URLRequest(url: url.appendingPathComponent("v1/capabilities"), timeoutInterval: 8)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200, data.count <= 1_000_000 else { throw RoutingError.unavailable }
        return try RoutingCapabilities.decode(data)
    }
}

@MainActor @Observable final class RoutingCatalog {
    enum Source: Equatable { case loading, server, fallback }

    private(set) var options: [RouteOption] = [.fastest]
    private(set) var source: Source = .loading
    private(set) var message: String?
    @ObservationIgnored private let client: RoutingCapabilitiesClient
    @ObservationIgnored private let isStatic: Bool
    @ObservationIgnored private var task: Task<Void, Never>?

    init(client: RoutingCapabilitiesClient = RoutingCapabilitiesClient()) {
        self.client = client
        self.isStatic = false
    }

    /// Preloaded catalog for previews/tests; never performs network work.
    init(options: [RouteOption]) {
        self.client = RoutingCapabilitiesClient()
        self.isStatic = true
        self.options = options.isEmpty ? [.fastest] : options
        self.source = .server
    }

    func load(endpoint: String) {
        guard !isStatic else { return }
        task?.cancel()
        source = .loading
        message = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let capabilities = try await client.fetch(baseURL: endpoint)
                try Task.checkCancellation()
                options = capabilities.routingOptions
                source = .server
            } catch is CancellationError {
                return
            } catch {
                options = [.fastest]
                source = .fallback
                message = String(localized: "Using standard routes. Route styles could not be loaded from the server.")
            }
        }
    }

    func visibleOptions(includeExperimental: Bool) -> [RouteOption] {
        let visible = options.filter { includeExperimental || !$0.isExperimental }
        return visible.isEmpty ? [.fastest] : visible
    }

    func option(id: String) -> RouteOption? { options.first { $0.id == id } }

    deinit { task?.cancel() }
}
