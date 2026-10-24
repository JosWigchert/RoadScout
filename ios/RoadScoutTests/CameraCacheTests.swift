import Foundation
import Testing
@testable import RoadScout

struct CameraCacheTests {
    @Test func wireDatesUnknownFieldsAndAbsentOptionals() throws {
        let data = Data(#"{"dataset":{"version":"v","coverage":"NL","lastCheckedAt":"2026-10-25T12:01:02.123456Z","lastChangedAt":"2026-10-25T12:01:02Z","sourceUpdatedAt":"bad","sources":null,"stale":false},"cameras":[{"id":"n","coordinate":{"latitude":52,"longitude":5},"kind":"fixed","association":"unknown","sourceIDs":[],"status":"mapped","future":1}],"averageSpeedZones":[],"truncated":false}"#.utf8)
        let response = try CameraClient.decode(data)
        #expect(response.dataset.lastCheckedAt != nil)
        #expect(response.dataset.lastChangedAt != nil)
        #expect(response.dataset.sourceUpdatedAt == nil)
        #expect(response.cameras[0].maxSpeedKph == nil)
        #expect(response.cameras[0].directionDegrees == nil)
        #expect(response.cameras[0].roadGeometry == nil)
        let roundTrip = try CameraClient.decode(JSONEncoder().encode(response))
        #expect(abs(roundTrip.dataset.lastCheckedAt!.timeIntervalSince(response.dataset.lastCheckedAt!)) < 0.001)
        #expect(roundTrip.dataset.version == response.dataset.version)
    }
    @Test func exactScopedDiskRoundTripAndFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = CameraDiskCache(directory: directory)
        let scope = CameraCacheScope(endpoint: "https://example.com", bounds: .init(south: 51, west: 4, north: 53, east: 6), routeFingerprint: "route-a")
        let entry = CameraCacheEntry(scope: scope, fetchedAt: Date(), response: .init(dataset: .init(coverage: "NL"), cameras: [], averageSpeedZones: [], truncated: false))
        try await cache.save(entry)
        let loaded = try await cache.load(scope: scope)
        #expect(loaded?.scope == scope)
        #expect(loaded?.fetchedAt == entry.fetchedAt)
        var changed = scope; changed.routeFingerprint = "route-b"
        #expect(try await cache.load(scope: changed) == nil)
        changed = scope; changed.endpoint = "https://other.example"
        #expect(try await cache.load(scope: changed) == nil)
        changed = scope; changed.bounds.north = 54
        #expect(try await cache.load(scope: changed) == nil)
        let invalid = CameraDiskCache(directory: directory.appendingPathComponent("missing").appendingPathComponent("cache"))
        #expect(try await invalid.load(scope: scope) == nil)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        try Data("corrupt".utf8).write(to: #require(files.first))
        await #expect(throws: (any Error).self) { try await cache.load(scope: scope) }
        let blocked = CameraDiskCache(directory: try #require(files.first))
        await #expect(throws: (any Error).self) { try await blocked.save(entry) }
    }
    @Test func polylineEncoderPreservesRoute() throws {
        let points = [GeoPoint(latitude: 52.123456, longitude: 5.123456), GeoPoint(latitude: 52.122222, longitude: 5.125555)]
        #expect(try Polyline6.decode(CameraRouteGeometry.encode(points)) == points)
        #expect(throws: (any Error).self) { try CameraClient.decode(Data("{}".utf8)) }
    }
}
