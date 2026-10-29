import Foundation

struct RouteTrafficMetadata: Decodable, Equatable, Sendable {
    var mode: String
    var token: String?
    var corridorKey: String?
    var leadMeters: Double?
    var coveragePercent: Double
    var expiresAt: Date?
    var isLive: Bool { mode == "live_partial" }
    private enum CodingKeys: String, CodingKey { case mode, token, corridorKey, leadMeters, coveragePercent, expiresAt }
    init(mode: String = "unavailable", token: String? = nil, corridorKey: String? = nil, leadMeters: Double? = nil,
         coveragePercent: Double = 0, expiresAt: Date? = nil) {
        self.mode = mode; self.token = token; self.corridorKey = corridorKey; self.leadMeters = leadMeters
        self.coveragePercent = coveragePercent; self.expiresAt = expiresAt
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(mode: (try? c.decode(String.self, forKey: .mode)) ?? "unavailable",
            token: try? c.decode(String.self, forKey: .token), corridorKey: try? c.decode(String.self, forKey: .corridorKey),
            leadMeters: try? c.decode(Double.self, forKey: .leadMeters),
            coveragePercent: min(100, max(0, (try? c.decode(Double.self, forKey: .coveragePercent)) ?? 0)),
            expiresAt: WeatherWireDate.parse(try? c.decode(String.self, forKey: .expiresAt)))
    }
}

struct TrafficSource: Decodable, Equatable, Sendable {
    let id: String
    let countries: [String]
    let attribution: String
    let stale: Bool
    let message: String?
}

struct TrafficFeature: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let sourceId: String
    let kind: String
    let title: String
    let points: [GeoPoint]
    let observedAt: Date
    let expiresAt: Date?
    let matched: Bool
    let congestion: String?
    let speedKph: Double?
    let travelSeconds: Double?
    let normalSeconds: Double?
    let routeStartMeters: Double?
    let routeEndMeters: Double?
    private enum CodingKeys: String, CodingKey {
        case id, sourceId, kind, title, geometry, observedAt, expiresAt, matched, congestion, speedKph, travelSeconds, normalSeconds, routeStartMeters, routeEndMeters
    }
    private struct Geometry: Decodable { let encoding: String; let data: String }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); sourceId = try c.decode(String.self, forKey: .sourceId)
        kind = try c.decode(String.self, forKey: .kind); title = try c.decode(String.self, forKey: .title)
        let g = try c.decode(Geometry.self, forKey: .geometry)
        guard g.encoding == "polyline6", let date = WeatherWireDate.parse(try c.decode(String.self, forKey: .observedAt)) else { throw TrafficClientError.invalidResponse }
        let decoded = try Polyline6.decode(g.data, minimumPoints: 1)
        guard !decoded.isEmpty, decoded.count <= 10_000, decoded.allSatisfy(\.isValid) else { throw TrafficClientError.invalidResponse }
        points = decoded; observedAt = date; matched = (try? c.decode(Bool.self, forKey: .matched)) ?? false
        expiresAt = WeatherWireDate.parse(try? c.decode(String.self, forKey: .expiresAt))
        congestion = try? c.decode(String.self, forKey: .congestion)
        speedKph = try? c.decode(Double.self, forKey: .speedKph)
        travelSeconds = try? c.decode(Double.self, forKey: .travelSeconds)
        normalSeconds = try? c.decode(Double.self, forKey: .normalSeconds)
        routeStartMeters = try? c.decode(Double.self, forKey: .routeStartMeters)
        routeEndMeters = try? c.decode(Double.self, forKey: .routeEndMeters)
    }
}

struct TrafficMapResponse: Decodable, Sendable {
    let sources: [TrafficSource]
    let features: [TrafficFeature]
    let routingEnabled: Bool
    let truncated: Bool
}

struct TrafficRefresh: Sendable {
    var routingEnabled = false
    var remainingSeconds: Double?
    var expiresAt: Date?
    var alternatives: [DrivingRoute] = []
}

struct TrafficOffer: Equatable, Identifiable {
    var id: String { corridorKey }
    let corridorKey: String
    let route: DrivingRoute
    let savingSeconds: Double
    let deadline: TimeInterval
    let expiresAt: Date
}

/// Pure policy uses monotonic countdown time and wall-clock source validity separately.
struct TrafficOfferPolicy {
    private(set) var offer: TrafficOffer?
    private var rejectedUntil: [String: TimeInterval] = [:]
    private var candidateSeen: (key: String, at: TimeInterval)?
    mutating func propose(route: DrivingRoute, currentSeconds: Double, now: Date, uptime: TimeInterval) {
        guard offer == nil else { return }
        guard let traffic = route.traffic, traffic.isLive, let key = traffic.corridorKey, !key.isEmpty,
              let expiry = traffic.expiresAt, expiry > now.addingTimeInterval(20),
              (traffic.leadMeters ?? 0) > 0, currentSeconds.isFinite else { return }
        let saving = currentSeconds - route.durationSeconds
        guard saving >= 120, saving >= currentSeconds * 0.05, (rejectedUntil[key] ?? 0) <= uptime else { return }
        // A second fresh assessment must confirm the same corridor before presenting.
        if candidateSeen?.key != key || uptime - (candidateSeen?.at ?? uptime) > 120 { candidateSeen = (key, uptime); return }
        guard uptime - (candidateSeen?.at ?? uptime) >= 15 else { return }
        if offer?.corridorKey == key { return }
        offer = TrafficOffer(corridorKey: key, route: route, savingSeconds: saving, deadline: uptime + 15, expiresAt: expiry)
    }
    mutating func reject(uptime: TimeInterval) { if let offer { rejectedUntil[offer.corridorKey] = uptime + 600 }; offer = nil; candidateSeen = nil; rejectedUntil = rejectedUntil.filter { $0.value > uptime } }
    mutating func cancel() { offer = nil; candidateSeen = nil }
    func expired(now: Date) -> Bool { offer.map { $0.expiresAt <= now } ?? false }
}
