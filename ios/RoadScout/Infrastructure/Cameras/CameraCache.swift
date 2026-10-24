import Foundation
import CryptoKit

struct CameraCacheScope: Codable, Equatable, Sendable {
    var endpoint: String
    var bounds: CameraBounds
    var routeFingerprint: String
}
struct CameraCacheEntry: Codable, Sendable {
    var scope: CameraCacheScope
    var fetchedAt: Date
    var response: CameraResponse
}
protocol CameraCaching: Sendable {
    func load(scope: CameraCacheScope) async throws -> CameraCacheEntry?
    func save(_ entry: CameraCacheEntry) async throws
}
actor CameraDiskCache: CameraCaching {
    let directory: URL
    let maximumEntries: Int
    init(directory: URL = URL.applicationSupportDirectory.appendingPathComponent("CameraCache", isDirectory: true), maximumEntries: Int = 32) {
        self.directory = directory
        self.maximumEntries = max(1, maximumEntries)
    }
    private func url(_ scope: CameraCacheScope) throws -> URL {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let digest = SHA256.hash(data: try encoder.encode(scope)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".json")
    }
    func load(scope: CameraCacheScope) throws -> CameraCacheEntry? {
        let path = try url(scope)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let data = try Data(contentsOf: path)
        guard data.count <= 2_500_000 else { throw CameraClientError.invalidResponse }
        let entry = try JSONDecoder().decode(CameraCacheEntry.self, from: data)
        guard entry.scope == scope else { return nil }
        _ = try CameraClient.decode(JSONEncoder().encode(entry.response))
        return entry
    }
    func save(_ entry: CameraCacheEntry) throws {
        let data = try JSONEncoder().encode(entry)
        guard data.count <= 2_500_000 else { throw CameraClientError.invalidResponse }
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
