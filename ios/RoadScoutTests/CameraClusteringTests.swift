import CoreLocation
import Foundation
import MapKit
import Testing
@testable import RoadScout

private func camera(_ id: String, _ latitude: Double, _ longitude: Double, heading: Double? = nil) -> CameraRecord {
    CameraRecord(id: id, coordinate: GeoPoint(latitude: latitude, longitude: longitude), kind: "fixed",
                 maxSpeedKph: 80, directionDegrees: heading, association: "relation",
                 sourceIDs: ["osm:node:\(id)"], status: "mapped")
}

private func trafficEvent(_ id: String, kind: String, _ latitude: Double, _ longitude: Double) throws -> TrafficFeature {
    let object: [String: Any] = ["id": id, "sourceId": "test", "kind": kind, "title": id,
        "geometry": ["encoding": "polyline6", "data": CameraRouteGeometry.encode([GeoPoint(latitude: latitude, longitude: longitude)])],
        "observedAt": "2026-10-28T12:00:00Z", "matched": false]
    return try JSONDecoder().decode(TrafficFeature.self, from: JSONSerialization.data(withJSONObject: object))
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

    @Test func nearbyCamerasAndTrafficEventsShareOneCluster() throws {
        let event = try trafficEvent("roadworks", kind: "roadworks", 51.0001, 4.0001)
        let items = MapOverlayClusterer.items(cameras: [camera("camera", 51.0, 4.0)], events: [event], in: nl)
        guard case .cluster(let cluster) = try #require(items.first) else {
            Issue.record("Expected a combined cluster"); return
        }
        #expect(cluster.count == 2)
        #expect(cluster.cameras.map(\.id) == ["camera"])
        #expect(cluster.events.map(\.id) == ["roadworks"])
        #expect(cluster.hasEvents && !cluster.hasAverageZone)
    }

    @Test func separatedTrafficEventsStayIndividual() throws {
        let nearby = try trafficEvent("near", kind: "incident", 52.0, 5.0)
        let far = try trafficEvent("far", kind: "roadworks", 51.0, 4.0)
        let items = MapOverlayClusterer.items(cameras: [], events: [nearby, far], in: nl)
        #expect(items.count == 2)
        #expect(items.allSatisfy { if case .event = $0 { return true }; return false })
    }

    @Test func clusteringGridDoesNotShiftWhenTheViewportPans() {
        let cameras = [camera("a", 52.0, 5.0), camera("b", 52.0002, 5.0002), camera("c", 52.1, 5.1)]
        let first = MapOverlayClusterer.items(cameras: cameras, events: [],
            in: CameraBounds(south: 51.9, west: 4.9, north: 52.2, east: 5.2))
        let panned = MapOverlayClusterer.items(cameras: cameras, events: [],
            in: CameraBounds(south: 51.91, west: 4.91, north: 52.21, east: 5.21))
        #expect(first.map(\.id) == panned.map(\.id))
    }

    @Test func zoomedOutUsesLargerGroupingDistance() {
        let cameras = [camera("a", 52.0, 5.0), camera("b", 52.002, 5.002)]
        let tight = MapOverlayClusterer.items(cameras: cameras, events: [],
            in: CameraBounds(south: 51.999, west: 4.999, north: 52.003, east: 5.003))
        let wide = MapOverlayClusterer.items(cameras: cameras, events: [],
            in: CameraBounds(south: 51.6, west: 4.6, north: 52.4, east: 5.4))
        #expect(tight.allSatisfy { if case .camera = $0 { return true }; return false })
        #expect(wide.contains { if case .cluster = $0 { return true }; return false })
        #expect(MapDisplayScale.showsClosureEndpoints(in: CameraBounds(south: 51.999, west: 4.999, north: 52.003, east: 5.003)))
        #expect(!MapDisplayScale.showsClosureEndpoints(in: CameraBounds(south: 51.6, west: 4.6, north: 52.4, east: 5.4)))
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
