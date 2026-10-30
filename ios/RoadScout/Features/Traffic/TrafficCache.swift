import CryptoKit
import Foundation

struct TrafficCacheScope: Codable, Equatable, Sendable {
    var endpoint: String
    var bounds: CameraBounds
    var routeID: String

    init(endpoint: String, bounds: CameraBounds, routeID: String?) {
        self.endpoint = endpoint
        self.bounds = CameraBounds(south: (bounds.south * 100).rounded() / 100,
                                   west: (bounds.west * 100).rounded() / 100,
                                   north: (bounds.north * 100).rounded() / 100,
                                   east: (bounds.east * 100).rounded() / 100)
        self.routeID = routeID ?? ""
    }

    var key: String { "\(endpoint)|\(bounds.south),\(bounds.west),\(bounds.north),\(bounds.east)|\(routeID)" }
}

struct TrafficCacheEntry: Codable, Sendable {
    var scope: TrafficCacheScope
    var fetchedAt: Date
    var response: TrafficMapResponse
}

protocol TrafficCaching: Sendable {
    func load(scope: TrafficCacheScope) async throws -> TrafficCacheEntry?
    func loadLatest(endpoint: String) async throws -> TrafficCacheEntry?
    func save(_ entry: TrafficCacheEntry) async throws
}

actor TrafficDiskCache: TrafficCaching {
    let directory: URL
    let maximumEntries: Int
    let maximumBytes: Int

    init(directory: URL = URL.applicationSupportDirectory.appendingPathComponent("TrafficCache", isDirectory: true),
         maximumEntries: Int = 8, maximumBytes: Int = 4_000_000) {
        self.directory = directory
        self.maximumEntries = max(1, maximumEntries)
        self.maximumBytes = max(1, maximumBytes)
    }

    private func url(_ scope: TrafficCacheScope) throws -> URL {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let digest = SHA256.hash(data: try encoder.encode(scope)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".json")
    }

    func load(scope: TrafficCacheScope) throws -> TrafficCacheEntry? {
        let path = try url(scope)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let data = try Data(contentsOf: path)
        guard data.count <= maximumBytes else { return nil }
        let entry = try JSONDecoder().decode(TrafficCacheEntry.self, from: data)
        guard entry.scope == scope else { return nil }
        return entry
    }

    func loadLatest(endpoint: String) throws -> TrafficCacheEntry? {
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "json" && $0.deletingPathExtension().lastPathComponent.count == 64 }
        var latest: TrafficCacheEntry?
        for file in files {
            guard let data = try? Data(contentsOf: file), data.count <= maximumBytes,
                  let entry = try? JSONDecoder().decode(TrafficCacheEntry.self, from: data),
                  entry.scope.endpoint == endpoint else { continue }
            if let current = latest {
                if entry.fetchedAt > current.fetchedAt { latest = entry }
            } else {
                latest = entry
            }
        }
        return latest
    }

    func save(_ entry: TrafficCacheEntry) throws {
        let data = try JSONEncoder().encode(entry)
        guard data.count <= maximumBytes else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url(entry.scope), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var folder = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "json" && $0.deletingPathExtension().lastPathComponent.count == 64 }
            .sorted { left, right in
                let a = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a < b
            }
        for file in files.prefix(max(0, files.count - maximumEntries)) { try FileManager.default.removeItem(at: file) }
    }
}

extension CameraBounds {
    func contains(_ other: CameraBounds) -> Bool {
        other.south >= south && other.north <= north && other.west >= west && other.east <= east
    }

    var trafficQueryBounds: CameraBounds {
        let latitudePadding = max(0.02, (north - south) * 0.5)
        let longitudePadding = max(0.02, (east - west) * 0.5)
        return CameraBounds(south: max(-85, south - latitudePadding), west: max(-180, west - longitudePadding),
                            north: min(85, north + latitudePadding), east: min(180, east + longitudePadding))
    }

    func contains(_ point: GeoPoint) -> Bool {
        point.latitude >= south && point.latitude <= north && point.longitude >= west && point.longitude <= east
    }
}
