import CoreLocation
import MapKit

struct CameraCluster: Identifiable, Equatable {
    let id: String
    let cameras: [CameraRecord]
    let coordinate: CLLocationCoordinate2D
    let bounds: CameraBounds

    static func == (lhs: CameraCluster, rhs: CameraCluster) -> Bool {
        lhs.id == rhs.id && lhs.cameras.map(\.id) == rhs.cameras.map(\.id)
    }
}

enum CameraMapItem: Identifiable {
    case camera(CameraRecord)
    case cluster(CameraCluster)

    var id: String {
        switch self {
        case .camera(let camera): "camera:\(camera.id)"
        case .cluster(let cluster): "cluster:\(cluster.id)"
        }
    }
}

/// Groups nearby mapped records so the map stays responsive at low zoom.
/// Individual records remain clickable; a cluster zooms into its own bounds.
enum CameraClusterer {
    static func items(_ cameras: [CameraRecord], in bounds: CameraBounds?, limit: Int = 120) -> [CameraMapItem] {
        guard !cameras.isEmpty else { return [] }
        let area = bounds.flatMap { $0.isValid ? $0 : nil }
            ?? CameraBounds(south: -85, west: -180, north: 85, east: 180)
        var divisions = divisions(for: max(area.north - area.south, area.east - area.west))
        while divisions >= 2 {
            let grouped = group(cameras, in: area, divisions: divisions)
            if grouped.count <= max(1, limit) { return grouped }
            if divisions == 2 { return [singleCluster(cameras)] }
            divisions -= 1
        }
        return [singleCluster(cameras)]
    }

    static func singleCluster(_ cameras: [CameraRecord]) -> CameraMapItem {
        let latitudes = cameras.map(\.coordinate.latitude)
        let longitudes = cameras.map(\.coordinate.longitude)
        let south = latitudes.min() ?? 0, north = latitudes.max() ?? 0
        let west = longitudes.min() ?? 0, east = longitudes.max() ?? 0
        let center = CLLocationCoordinate2D(latitude: (south + north) / 2, longitude: (west + east) / 2)
        return .cluster(CameraCluster(id: "all", cameras: cameras, coordinate: center,
                                      bounds: CameraBounds(south: south, west: west, north: north, east: east)))
    }

    private static func divisions(for span: Double) -> Int {
        switch span {
        case ..<0.01: 24
        case ..<0.05: 18
        case ..<0.2: 14
        case ..<0.8: 10
        default: 6
        }
    }

    private static func group(_ cameras: [CameraRecord], in bounds: CameraBounds, divisions: Int) -> [CameraMapItem] {
        let latSpan = max(0.0002, bounds.north - bounds.south)
        let lonSpan = max(0.0002, bounds.east - bounds.west)
        let latCell = max(0.0002, latSpan / Double(divisions))
        let lonCell = max(0.0002, lonSpan / Double(divisions))
        var cells: [String: [CameraRecord]] = [:]
        for camera in cameras {
            let row = Int(((camera.coordinate.latitude - bounds.south) / latCell).rounded(.down))
            let column = Int(((camera.coordinate.longitude - bounds.west) / lonCell).rounded(.down))
            cells["\(row):\(column)", default: []].append(camera)
        }
        return cells.map { key, values in
            if values.count == 1 { return .camera(values[0]) }
            let latitudes = values.map(\.coordinate.latitude)
            let longitudes = values.map(\.coordinate.longitude)
            let south = latitudes.min() ?? 0, north = latitudes.max() ?? 0
            let west = longitudes.min() ?? 0, east = longitudes.max() ?? 0
            let center = CLLocationCoordinate2D(latitude: (south + north) / 2, longitude: (west + east) / 2)
            return .cluster(CameraCluster(id: key, cameras: values, coordinate: center,
                                          bounds: CameraBounds(south: south, west: west, north: north, east: east)))
        }
        .sorted { $0.id < $1.id }
    }
}

enum CameraHeadingCone {
    /// A short beam showing the mapped enforcement travel direction, not camera hardware orientation.
    static func coordinates(for camera: CameraRecord, length: Double = 48, spread: Double = 17) -> [CLLocationCoordinate2D]? {
        guard let heading = camera.directionDegrees, heading.isFinite, (0..<360).contains(heading) else { return nil }
        let origin = camera.coordinate
        let left = destination(from: origin, distance: length, bearing: heading - spread)
        let right = destination(from: origin, distance: length, bearing: heading + spread)
        return [origin.coordinate, left.coordinate, right.coordinate]
    }

    static func destination(from point: GeoPoint, distance: Double, bearing: Double) -> GeoPoint {
        let radius = 6_371_000.0
        let angular = max(0, distance) / radius
        let theta = bearing * .pi / 180
        let phi1 = point.latitude * .pi / 180
        let lambda1 = point.longitude * .pi / 180
        let phi2 = asin(sin(phi1) * cos(angular) + cos(phi1) * sin(angular) * cos(theta))
        let lambda2 = lambda1 + atan2(sin(theta) * sin(angular) * cos(phi1),
                                      cos(angular) - sin(phi1) * sin(phi2))
        return GeoPoint(latitude: phi2 * 180 / .pi,
                        longitude: ((lambda2 * 180 / .pi + 540).truncatingRemainder(dividingBy: 360)) - 180)
    }
}

enum CameraCompassDirection {
    static func label(_ degrees: Double?) -> String? {
        guard let degrees, degrees.isFinite, (0..<360).contains(degrees) else { return nil }
        let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let index = Int(((degrees + 22.5) / 45).rounded(.down)) % 8
        return names[(index + 8) % 8]
    }
}

extension CameraBounds {
    var mapRect: MKMapRect {
        let a = MKMapPoint(CLLocationCoordinate2D(latitude: south, longitude: west))
        let b = MKMapPoint(CLLocationCoordinate2D(latitude: north, longitude: east))
        return MKMapRect(x: min(a.x, b.x), y: min(a.y, b.y),
                         width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
