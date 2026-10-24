#if DEBUG
import SwiftUI

private struct CameraFixtureClient: CameraProviding {
    let response: CameraResponse
    func fetch(bounds: CameraBounds, route: DrivingRoute?, endpoint: String) async throws -> CameraResponse { response }
}
private actor CameraFixtureCache: CameraCaching {
    func load(scope: CameraCacheScope) -> CameraCacheEntry? { nil }
    func save(_ entry: CameraCacheEntry) { }
}
@MainActor private final class CameraFixtureAudio: AudioAnnouncing {
    func speak(_ text: String, language: String) { }
    func stop() { }
}
@MainActor private final class CameraFixtureLocation: LocationProviding {
    var onEvent: ((LocationEvent) -> Void)?
    let point: GeoPoint
    let heading: Double
    let date: Date
    init(point: GeoPoint, heading: Double, date: Date) { self.point = point; self.heading = heading; self.date = date }
    func start() {
        onEvent?(.fix(LocationFix(latitude: point.latitude, longitude: point.longitude, speed: 13.89,
            speedAccuracy: 0.5, horizontalAccuracy: 3, course: heading, timestamp: date)))
    }
    func stop() { }
}

struct CameraDrivingPreview: View {
    @State private var driving: DrivingModel
    @State private var navigation: NavigationModel
    @State private var cameras: CameraAlertModel
    let origin: GeoPoint

    init(averageZone: Bool = false) {
        let date = Date()
        let navigation = NavigationModel(audio: CameraFixtureAudio(), now: { date })
        try? navigation.loadDemo()
        let route = navigation.selectedRoute
        let points = route?.geometry ?? [GeoPoint(latitude: 52.09, longitude: 5.12), GeoPoint(latitude: 52.091, longitude: 5.12)]
        let first = points[0], second = points[1]
        origin = first
        let heading = (NavigationTracker.bearing(first, second) + 360).truncatingRemainder(dividingBy: 360)
        let driving = DrivingModel(makeProvider: { _ in CameraFixtureLocation(point: first, heading: heading, date: date) }, now: { date })
        driving.start(source: .navigationReplay)
        navigation.start(fix: driving.fix)
        var records: [CameraRecord] = []
        var zones: [AverageSpeedZone] = []
        if averageZone {
            zones = [AverageSpeedZone(id: "fixture-zone", name: "Synthetic average-speed section", maxSpeedKph: 80,
                start: first, end: points.last, geometry: points, geometryVerified: true, directionDegrees: heading,
                sourceIDs: ["fixture"], status: "mapped", routeStartMeters: 0,
                routeEndMeters: route?.cumulativeMeters.last, routeMatch: "confirmed")]
        } else {
            records = [CameraRecord(id: "fixture-camera", coordinate: second, kind: "fixed", maxSpeedKph: 80,
                directionDegrees: heading, roadGeometry: points, roadWayIDs: [1], association: "relation",
                sourceIDs: ["fixture"], status: "mapped", routeDistanceMeters: route?.cumulativeMeters[1],
                routeLateralMeters: 0, routeMatch: "confirmed")]
        }
        let response = CameraResponse(dataset: CameraDatasetMetadata(version: "synthetic-camera-fixture", coverage: "NL",
            lastCheckedAt: date, lastChangedAt: date, sourceUpdatedAt: date,
            sources: [CameraSource(id: "fixture", name: "Synthetic development fixture", license: "Test data", attribution: "Not a real enforcement location")], stale: false),
            cameras: records, averageSpeedZones: zones, truncated: false)
        _driving = State(initialValue: driving)
        _navigation = State(initialValue: navigation)
        _cameras = State(initialValue: CameraAlertModel(client: CameraFixtureClient(response: response), cache: CameraFixtureCache(), now: { date }))
    }

    var body: some View {
        ContentView(model: driving, navigationModel: navigation, routePlanner: RoutePlanningModel(),
                    routeCatalog: RoutingCatalog(options: [.fastest]), cameraModel: cameras)
            .task { cameras.fetch(bounds: CameraViewportQuery.around(origin), route: navigation.selectedRoute, endpoint: "https://camera-fixture.invalid") }
            .defaultAppStorage(UserDefaults(suiteName: "RoadScout.CameraPreviews")!)
    }
}

#Preview("Camera · driving warning") { CameraDrivingPreview() }
#Preview("Camera · active average-speed section") { CameraDrivingPreview(averageZone: true) }
#endif
