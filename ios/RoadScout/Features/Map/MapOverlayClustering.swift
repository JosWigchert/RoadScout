import CoreLocation
import MapKit

struct MapOverlayCluster: Identifiable, Equatable {
    let id: String
    let cameras: [CameraRecord]
    let events: [TrafficFeature]
    let coordinate: CLLocationCoordinate2D
    let bounds: CameraBounds

    var count: Int { cameras.count + events.count }
    var hasEvents: Bool { !events.isEmpty }
    var hasAverageZone: Bool { cameras.contains { $0.kind == "average_speed" } }

    static func == (lhs: MapOverlayCluster, rhs: MapOverlayCluster) -> Bool {
        lhs.id == rhs.id && lhs.cameras.map(\.id) == rhs.cameras.map(\.id)
            && lhs.events.map(\.id) == rhs.events.map(\.id)
    }
}

enum MapOverlayItem: Identifiable {
    case camera(CameraRecord)
    case event(TrafficFeature)
    case cluster(MapOverlayCluster)

    var id: String {
        switch self {
        case .camera(let camera): "camera:\(camera.id)"
        case .event(let event): "event:\(event.id)"
        case .cluster(let cluster): "cluster:\(cluster.id)"
        }
    }
}

enum MapOverlayClusterer {
    static func items(cameras: [CameraRecord], events: [TrafficFeature], in bounds: CameraBounds?,
                      limit: Int = 120) -> [MapOverlayItem] {
        let entries = cameras.compactMap(Entry.camera) + events.compactMap(Entry.event)
        guard !entries.isEmpty else { return [] }
        let area = bounds.flatMap { $0.isValid ? $0 : nil }
            ?? CameraBounds(south: -85, west: -180, north: 85, east: 180)
        let span = max(area.north - area.south, area.east - area.west)
        var cellSize = cellSize(for: span)
        for _ in 0..<8 {
            let grouped = group(entries, cellSize: cellSize)
            if grouped.count <= max(1, limit) { return grouped }
            cellSize *= 2
        }
        return [singleCluster(entries)]
    }

    private enum Entry {
        case camera(CameraRecord, GeoPoint)
        case event(TrafficFeature, GeoPoint)

        var id: String {
            switch self {
            case .camera(let camera, _): "camera:\(camera.id)"
            case .event(let event, _): "event:\(event.id)"
            }
        }

        var point: GeoPoint {
            switch self {
            case .camera(_, let point), .event(_, let point): point
            }
        }

        var camera: CameraRecord? {
            if case .camera(let camera, _) = self { return camera }
            return nil
        }

        var event: TrafficFeature? {
            if case .event(let event, _) = self { return event }
            return nil
        }

        static func camera(_ camera: CameraRecord) -> Entry? {
            guard camera.coordinate.isValid else { return nil }
            return .camera(camera, camera.coordinate)
        }

        static func event(_ event: TrafficFeature) -> Entry? {
            guard let point = event.points.first, point.isValid else { return nil }
            return .event(event, point)
        }
    }

    private static func cellSize(for span: Double) -> Double {
        switch span {
        case ..<0.01: 0.0005
        case ..<0.05: 0.003
        case ..<0.2: 0.015
        case ..<0.8: 0.08
        case ..<3: 0.25
        default: max(0.5, span / 6)
        }
    }

    private static func group(_ entries: [Entry], cellSize: Double) -> [MapOverlayItem] {
        var cells: [String: [Entry]] = [:]
        for entry in entries {
            let row = Int((entry.point.latitude / cellSize).rounded(.down))
            let column = Int((entry.point.longitude / cellSize).rounded(.down))
            cells["grid:\(row):\(column)", default: []].append(entry)
        }
        return cells.map { key, values in
            values.count == 1 ? item(values[0]) : cluster(values, id: key)
        }
        .sorted { $0.id < $1.id }
    }

    private static func item(_ entry: Entry) -> MapOverlayItem {
        switch entry {
        case .camera(let camera, _): .camera(camera)
        case .event(let event, _): .event(event)
        }
    }

    private static func cluster(_ entries: [Entry], id: String) -> MapOverlayItem {
        let cameras = entries.compactMap(\.camera).sorted { $0.id < $1.id }
        let events = entries.compactMap(\.event).sorted { $0.id < $1.id }
        let latitudes = entries.map(\.point.latitude)
        let longitudes = entries.map(\.point.longitude)
        let south = latitudes.min() ?? 0, north = latitudes.max() ?? 0
        let west = longitudes.min() ?? 0, east = longitudes.max() ?? 0
        let center = CLLocationCoordinate2D(latitude: (south + north) / 2, longitude: (west + east) / 2)
        return .cluster(MapOverlayCluster(id: id, cameras: cameras, events: events, coordinate: center,
                                          bounds: CameraBounds(south: south, west: west, north: north, east: east)))
    }

    private static func singleCluster(_ entries: [Entry]) -> MapOverlayItem {
        cluster(entries, id: "all")
    }
}
