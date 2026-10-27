import Foundation

/// ISO8601 parsing that tolerates both fractional and whole-second timestamps.
/// The Go API emits whole seconds for some fields and fractional seconds for
/// others; the app must accept both without failing a usable response.
enum WeatherWireDate {
    static func parse(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = formatter.date(from: text) { return value }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

enum WeatherRecommendation: String, Codable, Equatable, Sendable {
    case roofDown = "roof_down"
    case rainRisk = "rain_risk"
    case unavailable

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = WeatherRecommendation(rawValue: raw) ?? .unavailable
    }
}

struct WeatherProviderInfo: Equatable, Sendable {
    var id: String = ""
    var name: String = ""
    var license: String = ""
    var attribution: String = ""
    var coverage: String = ""

    init(id: String = "", name: String = "", license: String = "", attribution: String = "", coverage: String = "") {
        self.id = id
        self.name = name
        self.license = license
        self.attribution = attribution
        self.coverage = coverage
    }
}

extension WeatherProviderInfo: Decodable {
    private enum CodingKeys: String, CodingKey { case id, name, license, attribution, coverage }
    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        self.init(id: WeatherDecoding.string(c, .id),
                  name: WeatherDecoding.string(c, .name),
                  license: WeatherDecoding.string(c, .license),
                  attribution: WeatherDecoding.string(c, .attribution),
                  coverage: WeatherDecoding.string(c, .coverage))
    }
}

struct WeatherSummary: Equatable, Sendable {
    var maxProbabilityPercent: Double = 0
    var maxIntensityMmPerHour: Double = 0
    var worstAt: Date?
    var worstCoordinate: GeoPoint?
    var sampleCount: Int = 0
    var rainRiskSampleCount: Int = 0
}

extension WeatherSummary: Decodable {
    private enum CodingKeys: String, CodingKey {
        case maxProbabilityPercent, maxIntensityMmPerHour, worstAt, worstCoordinate, sampleCount, rainRiskSampleCount
    }
    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        self.init(maxProbabilityPercent: WeatherDecoding.clampedPercent(c, .maxProbabilityPercent),
                  maxIntensityMmPerHour: max(0, WeatherDecoding.double(c, .maxIntensityMmPerHour)),
                  worstAt: WeatherDecoding.date(c, .worstAt),
                  worstCoordinate: WeatherDecoding.point(c, .worstCoordinate),
                  sampleCount: max(0, WeatherDecoding.int(c, .sampleCount)),
                  rainRiskSampleCount: max(0, WeatherDecoding.int(c, .rainRiskSampleCount)))
    }
}

struct WeatherSegment: Equatable, Sendable {
    var startMeters: Double
    var endMeters: Double
    var startAt: Date?
    var endAt: Date?
    var probabilityPercent: Double
    var intensityMmPerHour: Double
    var geometry: [GeoPoint]
}

extension WeatherSegment: Decodable {
    private enum CodingKeys: String, CodingKey {
        case startMeters, endMeters, startAt, endAt, probabilityPercent, intensityMmPerHour, geometry
    }
    private struct Geometry: Decodable { let encoding: String; let data: String }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let start = WeatherDecoding.double(c, .startMeters)
        let end = WeatherDecoding.double(c, .endMeters)
        guard start.isFinite, end.isFinite, start >= 0, end >= start else { throw WeatherClientError.invalidResponse }
        let encoded = try c.decode(Geometry.self, forKey: .geometry)
        guard encoded.encoding == "polyline6" else { throw WeatherClientError.invalidResponse }
        let points = try Polyline6.decode(encoded.data)
        guard points.count >= 2, points.allSatisfy(\.isValid) else { throw WeatherClientError.invalidResponse }
        self.init(startMeters: start, endMeters: end,
                  startAt: WeatherWireDate.parse(try? c.decode(String.self, forKey: .startAt)),
                  endAt: WeatherWireDate.parse(try? c.decode(String.self, forKey: .endAt)),
                  probabilityPercent: WeatherDecoding.clampedPercent(c, .probabilityPercent),
                  intensityMmPerHour: max(0, WeatherDecoding.double(c, .intensityMmPerHour)),
                  geometry: points)
    }
}

struct WeatherWarning: Equatable, Sendable {
    var code: String = ""
    var message: String = ""
}

extension WeatherWarning: Decodable {
    private enum CodingKeys: String, CodingKey { case code, message }
    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        self.init(code: WeatherDecoding.string(c, .code), message: WeatherDecoding.string(c, .message))
    }
}

struct WeatherResponse: Equatable, Sendable {
    static let maximumResponseBytes = 1_000_000

    var routeToken: String
    var generatedAt: Date?
    var departureAt: Date?
    var expiresAt: Date?
    var provider: WeatherProviderInfo
    var recommendation: WeatherRecommendation
    var summary: WeatherSummary?
    var segments: [WeatherSegment]
    var warnings: [WeatherWarning]

    init(routeToken: String, generatedAt: Date? = nil, departureAt: Date? = nil, expiresAt: Date? = nil,
         provider: WeatherProviderInfo = WeatherProviderInfo(), recommendation: WeatherRecommendation = .unavailable,
         summary: WeatherSummary? = nil, segments: [WeatherSegment] = [], warnings: [WeatherWarning] = []) {
        self.routeToken = routeToken
        self.generatedAt = generatedAt
        self.departureAt = departureAt
        self.expiresAt = expiresAt
        self.provider = provider
        self.recommendation = recommendation
        self.summary = summary
        self.segments = segments
        self.warnings = warnings
    }

    var hasRainRisk: Bool { recommendation == .rainRisk }
}

extension WeatherResponse: Decodable {
    private enum CodingKeys: String, CodingKey {
        case routeToken, generatedAt, departureAt, expiresAt, provider, recommendation, summary, segments, warnings
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(routeToken: try c.decode(String.self, forKey: .routeToken),
                  generatedAt: WeatherDecoding.date(c, .generatedAt),
                  departureAt: WeatherDecoding.date(c, .departureAt),
                  expiresAt: WeatherDecoding.date(c, .expiresAt),
                  provider: (try? c.decodeIfPresent(WeatherProviderInfo.self, forKey: .provider)) ?? nil ?? WeatherProviderInfo(),
                  recommendation: (try? c.decodeIfPresent(WeatherRecommendation.self, forKey: .recommendation)) ?? nil ?? .unavailable,
                  summary: (try? c.decodeIfPresent(WeatherSummary.self, forKey: .summary)) ?? nil,
                   segments: try c.decodeIfPresent([WeatherSegment].self, forKey: .segments) ?? [],
                  warnings: (try? c.decodeIfPresent([WeatherWarning].self, forKey: .warnings)) ?? nil ?? [])
    }
}

extension WeatherResponse {
    static func decode(_ data: Data) throws -> WeatherResponse {
        guard data.count <= maximumResponseBytes else { throw WeatherClientError.invalidResponse }
        do {
            return try JSONDecoder().decode(WeatherResponse.self, from: data)
        } catch is WeatherClientError {
            throw WeatherClientError.invalidResponse
        } catch {
            throw WeatherClientError.invalidResponse
        }
    }
}

/// Lenient field readers shared by the weather wire types. Safe fields fall back
/// to neutral defaults; geometry and coordinates are validated where they matter.
enum WeatherDecoding {
    static func string<K: CodingKey>(_ c: KeyedDecodingContainer<K>?, _ key: K) -> String {
        guard let c, let value = try? c.decode(String.self, forKey: key) else { return "" }
        return value
    }

    static func double<K: CodingKey>(_ c: KeyedDecodingContainer<K>?, _ key: K) -> Double {
        guard let c, let value = try? c.decode(Double.self, forKey: key), value.isFinite else { return 0 }
        return value
    }

    static func int<K: CodingKey>(_ c: KeyedDecodingContainer<K>?, _ key: K) -> Int {
        guard let c, let value = try? c.decode(Int.self, forKey: key) else { return 0 }
        return value
    }

    static func clampedPercent<K: CodingKey>(_ c: KeyedDecodingContainer<K>?, _ key: K) -> Double {
        min(100, max(0, double(c, key)))
    }

    static func date<K: CodingKey>(_ c: KeyedDecodingContainer<K>?, _ key: K) -> Date? {
        WeatherWireDate.parse(string(c, key))
    }

    static func point<K: CodingKey>(_ c: KeyedDecodingContainer<K>?, _ key: K) -> GeoPoint? {
        guard let c, let point = try? c.decode(GeoPoint.self, forKey: key), point.isValid else { return nil }
        return point
    }
}
