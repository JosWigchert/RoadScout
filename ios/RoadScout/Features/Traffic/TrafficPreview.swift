#if DEBUG
import MapKit
import SwiftUI

/// Visual fixture only. All traffic/route geometry is synthetic; no provider or GPS is opened.
struct TrafficPreview: View {
    private let route: DrivingRoute
    private let alternative: DrivingRoute
    private let features: [TrafficDisplayFeature]
    @State private var camera: MapCameraPosition
    @State private var offer: TrafficOffer?
    @State private var result: String?

    init() {
        let points = [GeoPoint(latitude: 52.09, longitude: 5.12), GeoPoint(latitude: 52.091, longitude: 5.12), GeoPoint(latitude: 52.091, longitude: 5.1216)]
        let maneuver = RouteManeuver(id: "fixture", instruction: "Synthetic route", spokenInstruction: "Synthetic route",
            beginIndex: 0, endIndex: 2, seconds: 900, type: "depart", modifier: "straight")
        route = try! DrivingRoute(geometry: points, distanceMeters: 220, durationSeconds: 900, maneuvers: [maneuver])
        alternative = try! DrivingRoute(geometry: [points[0], GeoPoint(latitude: 52.0912, longitude: 5.1195), points[2]],
            distanceMeters: 300, durationSeconds: 600, maneuvers: [maneuver],
            traffic: RouteTrafficMetadata(mode: "live_partial", token: "fixture", corridorKey: "fixture", leadMeters: 1500,
                coveragePercent: 50, expiresAt: Date().addingTimeInterval(600)))
        let closurePoints = [GeoPoint(latitude: 52.0904, longitude: 5.1202), GeoPoint(latitude: 52.0908, longitude: 5.1202)]
        let feature = trafficFixture("fixture", kind: "flow", geometry: points, congestion: "heavy",
                                     routeEndMeters: route.cumulativeMeters.last!)
        let closure = trafficFixture("closure", kind: "closure", geometry: closurePoints)
        let roadworks = trafficFixture("roadworks", kind: "roadworks",
                                       geometry: [GeoPoint(latitude: 52.0902, longitude: 5.121)])
        let slow = trafficFixture("slow", kind: "flow",
                                  geometry: [GeoPoint(latitude: 52.0893, longitude: 5.1202),
                                             GeoPoint(latitude: 52.0893, longitude: 5.1212)],
                                  congestion: "slow")
        features = TrafficDisplayFeature.make([feature, closure, roadworks, slow], route: route)
        let rect = MKPolyline(coordinates: points.map(\.coordinate), count: points.count).boundingMapRect
        _camera = State(initialValue: .rect(rect.insetBy(dx: -2000, dy: -2000)))
        _offer = State(initialValue: TrafficOffer(corridorKey: "fixture", route: alternative, savingSeconds: 300,
            deadline: ProcessInfo.processInfo.systemUptime + 15, expiresAt: Date().addingTimeInterval(600)))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Map(position: $camera) {
                MapPolyline(coordinates: alternative.geometry.map(\.coordinate))
                    .stroke(.purple, style: StrokeStyle(lineWidth: 5, dash: [8, 5]))
                MapTrafficLayers(routeGeometry: RouteProgressGeometry(route: route, traveledMeters: 40),
                                 flowFeatures: features.filter { $0.feature.kind == "flow" },
                                 closureFeatures: features.filter { $0.feature.kind == "closure" },
                                 cameras: [],
                                 events: features.filter { $0.feature.kind != "flow" && $0.feature.kind != "closure" }.map(\.feature),
                                 zones: [],
                                 bounds: nil,
                                 selectCamera: { _ in },
                                 selectTraffic: { _ in },
                                 selectCluster: { _ in })
                Marker("Synthetic destination", coordinate: route.geometry.last!.coordinate)
            }.mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll)).ignoresSafeArea()
            VStack(spacing: 12) {
                Spacer()
                if let offer {
                    TrafficOfferCard(offer: offer, accept: { result = "Simulated switch confirmed"; self.offer = nil },
                        reject: { result = "Current route kept"; self.offer = nil })
                }
                Text(result ?? "SYNTHETIC TRAFFIC · NOT REAL CONDITIONS")
                    .font(.caption.bold()).padding(12).background(.regularMaterial, in: Capsule())
            }.padding(16)
        }
    }
}

private func trafficFixture(_ id: String, kind: String, geometry: [GeoPoint], congestion: String? = nil,
                            routeEndMeters: Double? = nil) -> TrafficFeature {
    var object: [String: Any] = ["id": id, "sourceId": "synthetic", "kind": kind, "title": id,
        "geometry": ["encoding": "polyline6", "data": CameraRouteGeometry.encode(geometry)],
        "observedAt": WeatherWireDate.string(from: Date()), "matched": true]
    object["congestion"] = congestion
    object["routeStartMeters"] = routeEndMeters == nil ? nil : 0
    object["routeEndMeters"] = routeEndMeters
    return try! JSONDecoder().decode(TrafficFeature.self, from: JSONSerialization.data(withJSONObject: object))
}

#Preview("Traffic · map and timed alternative") { TrafficPreview() }
#endif
