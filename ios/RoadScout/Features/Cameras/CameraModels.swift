import Foundation

struct CameraBounds: Codable, Equatable, Sendable {
    var south: Double
    var west: Double
    var north: Double
    var east: Double
    var center: GeoPoint { .init(latitude: (south + north) / 2, longitude: (west + east) / 2) }
    var isValid: Bool {
        [south, west, north, east].allSatisfy(\.isFinite) && south <= north && west <= east
            && south >= -90 && north <= 90 && west >= -180 && east <= 180
    }
}

struct CameraSource: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var license: String
    var attribution: String
    var url: String? = nil
}

struct CameraDatasetMetadata: Codable, Equatable, Sendable {
    var version: String = ""
    var coverage: String = ""
    var lastCheckedAt: Date? = nil
    var lastChangedAt: Date? = nil
    var sourceUpdatedAt: Date? = nil
    var sources: [CameraSource] = []
    var incompleteZoneCount: Int = 0
    var stale: Bool = true

    enum CodingKeys: String, CodingKey {
        case version, coverage, lastCheckedAt, lastChangedAt, sourceUpdatedAt, sources, incompleteZoneCount, stale
    }
    init(version: String = "", coverage: String = "", lastCheckedAt: Date? = nil,
         lastChangedAt: Date? = nil, sourceUpdatedAt: Date? = nil, sources: [CameraSource] = [],
         incompleteZoneCount: Int = 0, stale: Bool = true) {
        self.version = version; self.coverage = coverage; self.lastCheckedAt = lastCheckedAt
        self.lastChangedAt = lastChangedAt; self.sourceUpdatedAt = sourceUpdatedAt
        self.sources = sources; self.incompleteZoneCount = incompleteZoneCount; self.stale = stale
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        coverage = try c.decodeIfPresent(String.self, forKey: .coverage) ?? ""
        func date(_ key: CodingKeys) -> Date? {
            guard let text = try? c.decode(String.self, forKey: key) else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let value = formatter.date(from: text) { return value }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: text)
        }
        lastCheckedAt = date(.lastCheckedAt); lastChangedAt = date(.lastChangedAt); sourceUpdatedAt = date(.sourceUpdatedAt)
        sources = try c.decodeIfPresent([CameraSource].self, forKey: .sources) ?? []
        incompleteZoneCount = try c.decodeIfPresent(Int.self, forKey: .incompleteZoneCount) ?? 0
        stale = try c.decodeIfPresent(Bool.self, forKey: .stale) ?? true
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version); try c.encode(coverage, forKey: .coverage)
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try c.encodeIfPresent(lastCheckedAt.map(f.string), forKey: .lastCheckedAt)
        try c.encodeIfPresent(lastChangedAt.map(f.string), forKey: .lastChangedAt)
        try c.encodeIfPresent(sourceUpdatedAt.map(f.string), forKey: .sourceUpdatedAt)
        try c.encode(sources, forKey: .sources); try c.encode(incompleteZoneCount, forKey: .incompleteZoneCount)
        try c.encode(stale, forKey: .stale)
    }
}

struct CameraRecord: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var coordinate: GeoPoint
    var kind: String
    var name: String? = nil
    var maxSpeedKph: Double? = nil
    var directionDegrees: Double? = nil
    var roadRef: String? = nil
    var roadGeometry: [GeoPoint]? = nil
    var roadWayIDs: [Int64]? = nil
    var association: String
    var sourceIDs: [String]
    var status: String
    var routeDistanceMeters: Double? = nil
    var routeLateralMeters: Double? = nil
    var routeMatch: String? = nil
}

struct AverageSpeedZone: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var name: String? = nil
    var maxSpeedKph: Double? = nil
    var start: GeoPoint? = nil
    var end: GeoPoint? = nil
    var geometry: [GeoPoint]
    var geometryVerified: Bool
    var directionDegrees: Double? = nil
    var sourceIDs: [String]
    var status: String
    var roadWayIDs: [Int64]? = nil
    var routeStartMeters: Double? = nil
    var routeEndMeters: Double? = nil
    var routeMatch: String? = nil
}

struct CameraAPIWarning: Codable, Equatable, Sendable { var code: String; var message: String }
struct CameraResponse: Codable, Sendable {
    var dataset: CameraDatasetMetadata
    var cameras: [CameraRecord]
    var averageSpeedZones: [AverageSpeedZone]
    var truncated: Bool
    var warnings: [CameraAPIWarning]? = nil
}

struct CameraWarningSettings: Equatable, Sendable {
    var enabled: Bool = true
    var audioEnabled: Bool = true
    var warningDistanceMeters: Double = 500
}

struct CameraWarning: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var distanceMeters: Double?
    var maxSpeedKph: Double?
    var isAverageZone: Bool
    var isInsideZone: Bool
    var confident: Bool
    var announcement: String
}
