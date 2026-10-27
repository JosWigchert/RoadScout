import CoreLocation
import MapKit
import Testing
@testable import RoadScout

private func camera(_ id: String, _ latitude: Double, _ longitude: Double, heading: Double? = nil) -> CameraRecord {
    CameraRecord(id: id, coordinate: GeoPoint(latitude: latitude, longitude: longitude), kind: "fixed",
                 maxSpeedKph: 80, directionDegrees: heading, association: "relation",
                 sourceIDs: ["osm:node:\(id)"], status: "mapped")
}

struct CameraClusteringTests {
    private let nl = CameraBounds(south: 50.7, west: 3.1, north: 53.7, east: 7.3)

    @Test func separatedCamerasStayIndividualAndNearbyCamerasCluster() {
        let cameras = [camera("a", 52.0, 5.0), camera("b", 52.5, 6.0),
                       camera("c", 51.0, 4.0), camera("d", 51.0001, 4.0001), camera("e", 51.0002, 4.0002)]
        let items = CameraClusterer.items(cameras, in: nl)
        let individuals = items.compactMap { if case .camera(let value) = $0 { value.id } else { nil } }
        let clusters = items.compactMap { if case .cluster(let value) = $0 { value } else { nil } }
        #expect(individuals.contains("a") && individuals.contains("b"))
        #expect(clusters.contains { Set($0.cameras.map(\.id)) == ["c", "d", "e"] })
        #expect(items.count < cameras.count)
    }

    @Test func denseMapIsBoundedByClustersAndAlwaysProducesAnItem() {
        let cameras = (0..<600).map { index in
            camera("\(index)", 52.0 + Double(index % 20) * 0.0002, 5.0 + Double(index / 20) * 0.0002)
        }
        let items = CameraClusterer.items(cameras, in: nl, limit: 40)
        #expect(!items.isEmpty)
        #expect(items.count <= 40)
        #expect(items.allSatisfy { item in
            if case .cluster(let cluster) = item { return !cluster.cameras.isEmpty }
            return true
        })
    }

    @Test func zoomingIntoClusterBoundsRevealsSmallerItems() {
        let cameras = (0..<40).map { index in
            camera("\(index)", 52.0 + Double(index) * 0.0005, 5.0 + Double(index) * 0.0005)
        }
        let broad = CameraClusterer.items(cameras, in: nl)
        guard case .cluster(let cluster) = broad.first(where: { if case .cluster = $0 { return true }; return false }) else {
            Issue.record("Expected a cluster at NL zoom"); return
        }
        let tight = CameraClusterer.items(cluster.cameras, in: cluster.bounds)
        #expect(tight.count > broad.count)
    }

    @Test func headingConeUsesEnforcedTravelBearingAndNeedsKnownDirection() throws {
        let known = camera("known", 52, 5, heading: 90)
        let cone = try #require(CameraHeadingCone.coordinates(for: known))
        #expect(cone.count == 3)
        #expect(cone[0].longitude == 5)
        #expect(cone[1].longitude > cone[0].longitude && cone[2].longitude > cone[0].longitude)
        #expect(CameraHeadingCone.coordinates(for: camera("unknown", 52, 5)) == nil)
        #expect(CameraCompassDirection.label(0) == "N")
        #expect(CameraCompassDirection.label(90) == "E")
        #expect(CameraCompassDirection.label(225) == "SW")
        #expect(CameraCompassDirection.label(nil) == nil)
    }
}
