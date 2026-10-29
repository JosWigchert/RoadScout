import CoreLocation

struct GeoPoint: Codable, Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    var isValid: Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
    func distance(to other: GeoPoint) -> Double {
        let radians = Double.pi / 180
        let a = pow(sin((other.latitude - latitude) * radians / 2), 2)
            + cos(latitude * radians) * cos(other.latitude * radians)
            * pow(sin((other.longitude - longitude) * radians / 2), 2)
        return 6_371_000 * 2 * asin(sqrt(min(1, max(0, a))))
    }
}

typealias Destination = SearchResult

struct RoutePreferences: Equatable, Sendable {
    var avoidTolls = false
    var avoidHighways = false
}

struct RouteManeuver: Equatable, Sendable {
    let id: String
    let instruction: String
    let spokenInstruction: String
    let beginIndex: Int
    let endIndex: Int
    let seconds: Double
    let type: String
    let modifier: String
    var spokenAlert: String? = nil
    var spokenAfter: String? = nil
    var multiCue = false
    var streetNames: [String] = []
    var distanceMeters: Double? = nil
}

struct DrivingRoute: Identifiable, Equatable, Sendable {
    let id: String
    let geometry: [GeoPoint]
    let cumulativeMeters: [Double]
    let distanceMeters: Double
    let durationSeconds: Double
    let maneuvers: [RouteManeuver]
    let timing: [RouteTimeAnchor]
    let language: String
    let attribution: String
    let objective: RoutePlanningProfile?
    let experiment: RouteExperiment?
    let weatherToken: String?
    let weatherExpiresAt: Date?
    let traffic: RouteTrafficMetadata?

    init(geometry: [GeoPoint], distanceMeters: Double, durationSeconds: Double,
          maneuvers: [RouteManeuver], id: String = UUID().uuidString, timing: [RouteTimeAnchor] = [],
          language: String = "en-US", attribution: String = "© OpenStreetMap contributors",
          objective: RoutePlanningProfile? = nil, experiment: RouteExperiment? = nil,
          weatherToken: String? = nil, weatherExpiresAt: Date? = nil, traffic: RouteTrafficMetadata? = nil) throws {
        guard geometry.count >= 2, geometry.count <= 100_000, geometry.allSatisfy(\.isValid),
              distanceMeters.isFinite, distanceMeters > 0,
               durationSeconds.isFinite, durationSeconds >= 0, !maneuvers.isEmpty,
              maneuvers.allSatisfy({ $0.beginIndex >= 0 && $0.endIndex >= $0.beginIndex
                  && $0.endIndex < geometry.count && $0.seconds.isFinite && $0.seconds >= 0 }),
              zip(maneuvers, maneuvers.dropFirst()).allSatisfy({ $0.beginIndex <= $1.beginIndex }) else {
            throw RoutingError.invalidResponse
        }
        var cumulative = [0.0]
        for index in 1..<geometry.count {
            cumulative.append(cumulative[index - 1] + geometry[index - 1].distance(to: geometry[index]))
        }
        guard cumulative.last! > 0 else { throw RoutingError.invalidResponse }
        self.id = id
        self.geometry = geometry
        cumulativeMeters = cumulative
        self.distanceMeters = distanceMeters
        self.durationSeconds = durationSeconds
        self.maneuvers = maneuvers
        self.timing = timing
        self.language = language
        self.attribution = attribution
        self.objective = objective
        self.experiment = experiment
        self.weatherToken = weatherToken
        self.weatherExpiresAt = weatherExpiresAt
        self.traffic = traffic
    }

    func elapsedSeconds(at meters: Double) -> Double {
        guard timing.count >= 2 else { return durationSeconds * min(1, max(0, meters / cumulativeMeters.last!)) }
        for (a, b) in zip(timing, timing.dropFirst()) {
            let start = cumulativeMeters[a.geometryIndex], end = cumulativeMeters[b.geometryIndex]
            if meters <= end, end > start {
                return a.elapsedSeconds + (b.elapsedSeconds - a.elapsedSeconds) * min(1, max(0, (meters - start) / (end - start)))
            }
        }
        return durationSeconds
    }
}

struct RouteTimeAnchor: Codable, Equatable, Sendable {
    let geometryIndex: Int
    let elapsedSeconds: Double
}

struct RouteRequest: Sendable {
    let origin: GeoPoint
    let destination: GeoPoint
    let preferences: RoutePreferences
    var originHeading: Double? = nil
    var objective: RoutePlanningProfile = .fastest
    var maxExtraDurationPercent: Int = 30
}

struct RouteExperiment: Codable, Equatable, Sendable {
    let requestedObjective: String
    let effectiveObjective: String
    let status: String
    let method: String
    let baselineDurationSeconds: Double
    let extraDurationPercent: Double
    let detourLimitPercent: Int
    let bendCount: Int
    let bendsPerKilometer: Double
    let countrysideShare: Double

    private enum CodingKeys: String, CodingKey {
        case requestedObjective, effectiveObjective, status, method, baselineDurationSeconds
        case extraDurationPercent, detourLimitPercent, bendCount, bendsPerKilometer, countrysideShare
    }

    // Lenient: experimental metadata may evolve server-side without breaking a
    // working route. Missing or mistyped fields fall back to neutral values.
    init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        requestedObjective = Self.string(container, .requestedObjective)
        effectiveObjective = Self.string(container, .effectiveObjective)
        status = Self.string(container, .status)
        method = Self.string(container, .method)
        baselineDurationSeconds = Self.number(container, .baselineDurationSeconds)
        extraDurationPercent = Self.number(container, .extraDurationPercent)
        detourLimitPercent = Int(Self.number(container, .detourLimitPercent))
        bendCount = Int(Self.number(container, .bendCount))
        bendsPerKilometer = Self.number(container, .bendsPerKilometer)
        countrysideShare = Self.number(container, .countrysideShare)
    }

    private static func string(_ container: KeyedDecodingContainer<CodingKeys>?, _ key: CodingKeys) -> String {
        guard let container, let value = try? container.decode(String.self, forKey: key) else { return "" }
        return value
    }

    private static func number(_ container: KeyedDecodingContainer<CodingKeys>?, _ key: CodingKeys) -> Double {
        guard let container, let value = try? container.decode(Double.self, forKey: key), value.isFinite else { return 0 }
        return value
    }

    var fallbackMessage: String? {
        switch status {
        case "metadata_unavailable": String(localized: "Road metadata unavailable. Showing Fastest instead of claiming a scenic or winding route.")
        case "no_improvement": String(localized: "No verified improvement among the candidates within the detour limit. Showing Fastest.")
        default: nil
        }
    }
}

enum RoutingError: Error, LocalizedError, Equatable {
    case invalidEndpoint, invalidResponse, noRoute, unavailable, http(Int)
    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: String(localized: "Set a supported RoadScout API base URL in Settings.")
        case .invalidResponse: String(localized: "The routing service returned an unusable route.")
        case .noRoute: String(localized: "No driving route found. Check the routing graph's coverage and destination.")
        case .unavailable: String(localized: "Routing is unreachable. Loaded routes remain available; new routes cannot be calculated.")
        case .http(let code): String(localized: "Routing service returned HTTP \(code).")
        }
    }
}

protocol RoutingProviding: Sendable {
    func routes(for request: RouteRequest) async throws -> [DrivingRoute]
}
