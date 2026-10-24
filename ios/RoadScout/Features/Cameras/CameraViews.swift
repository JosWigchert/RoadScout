import SwiftUI
import MapKit

struct CameraMapContent: MapContent {
    let cameras: [CameraRecord]
    let zones: [AverageSpeedZone]
    let bounds: CameraBounds?
    let selectCamera: (CameraRecord) -> Void
    let selectCluster: (CameraCluster) -> Void

    private var items: [CameraMapItem] { CameraClusterer.items(cameras, in: bounds) }

    @MapContentBuilder var body: some MapContent {
        ForEach(zones.filter { $0.geometryVerified && $0.geometry.count > 1 }) { zone in
            MapPolyline(coordinates: zone.geometry.map(\.coordinate))
                .stroke(.purple.opacity(zone.routeMatch == "confirmed" ? 0.9 : 0.45),
                        style: StrokeStyle(lineWidth: 5, dash: [8, 6]))
        }
        ForEach(cameras) { camera in
            if let cone = CameraHeadingCone.coordinates(for: camera) {
                MapPolygon(coordinates: cone)
                    .foregroundStyle(.blue.opacity(camera.routeMatch == "confirmed" ? 0.30 : 0.16))
                    .stroke(.blue.opacity(0.55), lineWidth: 1)
            }
        }
        ForEach(items) { item in
            switch item {
            case .camera(let camera):
                Annotation(camera.name ?? String(localized: "Mapped camera"),
                           coordinate: camera.coordinate.coordinate) {
                    Button { selectCamera(camera) } label: {
                        CameraDot(averageZone: camera.kind == "average_speed",
                                  onRoute: camera.routeMatch == "confirmed")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(accessibilityLabel(for: camera))
                    .accessibilityHint("Shows mapped speed and heading")
                }
                .annotationTitles(.hidden)
            case .cluster(let cluster):
                Annotation(String(localized: "\(cluster.cameras.count) mapped cameras"),
                           coordinate: cluster.coordinate) {
                    Button { selectCluster(cluster) } label: {
                        CameraClusterBadge(count: cluster.cameras.count,
                                           hasAverageZone: cluster.cameras.contains { $0.kind == "average_speed" })
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "\(cluster.cameras.count) mapped cameras. Zoom in."))
                }
                .annotationTitles(.hidden)
            }
        }
        ForEach(zones) { zone in
            if let start = zone.start {
                Annotation("Average-speed section start", coordinate: start.coordinate) {
                    CameraDot(averageZone: true, onRoute: zone.routeMatch == "confirmed")
                }.annotationTitles(.hidden)
            }
            if let end = zone.end {
                Annotation("Average-speed section end", coordinate: end.coordinate) {
                    Image(systemName: "flag.checkered").font(.caption.bold()).foregroundStyle(.white)
                        .padding(6).background(.purple, in: Circle())
                }.annotationTitles(.hidden)
            }
        }
    }

    private func accessibilityLabel(for camera: CameraRecord) -> String {
        var parts = [camera.kind == "average_speed" ? String(localized: "Mapped average-speed device") : String(localized: "Mapped camera")]
        if let speed = camera.maxSpeedKph, speed.isFinite, speed > 0 {
            parts.append(String(localized: "limit \(Int(speed.rounded())) kilometers per hour"))
        }
        if let heading = CameraCompassDirection.label(camera.directionDegrees) { parts.append(heading) }
        return parts.joined(separator: ", ")
    }
}

struct CameraDot: View {
    let averageZone: Bool
    let onRoute: Bool

    var body: some View {
        ZStack {
            Circle().fill(.blue)
            Image(systemName: averageZone ? "speedometer" : "camera.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: onRoute ? 28 : 23, height: onRoute ? 28 : 23)
        .overlay(Circle().strokeBorder(.white.opacity(0.95), lineWidth: 3))
        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
    }
}

struct CameraClusterBadge: View {
    let count: Int
    let hasAverageZone: Bool

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.caption2.bold()).monospacedDigit()
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(hasAverageZone ? Color.purple : Color.blue, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.95), lineWidth: 3))
            .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
    }
}

struct CameraDetailCard: View {
    let camera: CameraRecord
    let unit: SpeedUnit
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                CameraDot(averageZone: camera.kind == "average_speed", onRoute: camera.routeMatch == "confirmed")
                VStack(alignment: .leading, spacing: 2) {
                    Text(camera.kind == "average_speed"
                         ? String(localized: "Average-speed device")
                         : String(localized: "Mapped camera"))
                        .font(.headline)
                    if let road = camera.roadRef, !road.isEmpty {
                        Text(road).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: close) { Image(systemName: "xmark").font(.caption.bold()) }
                    .buttonStyle(MapIconButtonStyle())
                    .accessibilityLabel("Close camera details")
            }
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mapped limit").font(.caption).foregroundStyle(.secondary)
                    Text(limit).font(.title3.bold()).monospacedDigit()
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Direction").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        if let heading = camera.directionDegrees {
                            Image(systemName: "arrow.up").rotationEffect(.degrees(heading))
                        }
                        Text(heading).font(.title3.bold())
                    }
                }
                Spacer(minLength: 0)
            }
            if camera.routeMatch == "confirmed" {
                Label("Associated with your route", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Mapped record only. Active enforcement is not confirmed.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(16)
        .glassFloatingControl(cornerRadius: 24)
        .accessibilityElement(children: .contain)
    }

    private var limit: String {
        guard let speed = camera.maxSpeedKph, speed.isFinite, speed > 0 else { return String(localized: "Unknown") }
        let converted = unit.convert(metersPerSecond: speed / 3.6).formatted(.number.precision(.fractionLength(0)))
        return "\(converted) \(unit.symbol)"
    }

    private var heading: String {
        guard let degrees = camera.directionDegrees, degrees.isFinite else { return String(localized: "Unknown") }
        let compass = CameraCompassDirection.label(degrees) ?? ""
        return "\(compass) · \(Int(degrees.rounded()))°"
    }
}

struct CameraWarningStrip: View {
    let warning: CameraWarning
    let unit: SpeedUnit
    let cached: Bool
    let stale: Bool

    var body: some View {
        HStack(spacing: 12) {
            CameraDot(averageZone: warning.isAverageZone, onRoute: warning.confident)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(warning.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let speed = warning.maxSpeedKph, speed.isFinite, speed > 0 {
                Text(unit.convert(metersPerSecond: speed / 3.6).formatted(.number.precision(.fractionLength(0))))
                    .font(.headline).monospacedDigit().padding(8)
                    .background(.background, in: Circle())
                    .overlay(Circle().strokeBorder(.secondary.opacity(0.5), lineWidth: 2))
                    .accessibilityLabel("Mapped camera limit")
            }
        }
        .padding(14)
        .glassFloatingControl(cornerRadius: 22)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        var items: [String] = []
        if let meters = warning.distanceMeters { items.append(PlaceDistanceFormatter.string(meters, unit: unit)) }
        if warning.isInsideZone { items.append(String(localized: "Average-speed measurement not yet available")) }
        if !warning.confident { items.append(String(localized: "Road/direction uncertain")) }
        if cached { items.append(String(localized: "Cached area")) }
        if stale { items.append(String(localized: "Data may be outdated")) }
        return items.joined(separator: " · ")
    }
}

struct CameraDataSettings: View {
    let metadata: CameraDatasetMetadata?
    let cached: Bool
    let status: String?

    var body: some View {
        Section("Camera data · Netherlands") {
            if let metadata, !metadata.version.isEmpty {
                LabeledContent("Coverage", value: "Netherlands · mapped records")
                if let checked = metadata.lastCheckedAt {
                    LabeledContent("Last checked", value: checked.formatted(date: .abbreviated, time: .shortened))
                }
                if let changed = metadata.lastChangedAt {
                    LabeledContent("Dataset changed", value: changed.formatted(date: .abbreviated, time: .shortened))
                }
                if let source = metadata.sourceUpdatedAt {
                    LabeledContent("Source snapshot", value: source.formatted(date: .abbreviated, time: .shortened))
                }
                if metadata.incompleteZoneCount > 0 {
                    Text("\(metadata.incompleteZoneCount) average-speed sections have incomplete geometry and are not used for zone warnings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if cached { Text("Using cached query area.").font(.caption) }
                if metadata.stale { Text("Camera data may be outdated.").font(.caption).foregroundStyle(.secondary) }
                ForEach(metadata.sources, id: \.id) { source in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(source.name).font(.subheadline)
                        Text("\(source.attribution) · \(source.license)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Camera data has not been loaded from your RoadScout server yet.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            Text("Open mapped records may be incomplete. A mapped location does not confirm active enforcement. Offline support covers saved query areas only.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

#Preview("Camera · warning strip") {
    CameraWarningStrip(warning: CameraWarning(id: "demo", title: "Mapped camera ahead", distanceMeters: 350,
        maxSpeedKph: 80, isAverageZone: false, isInsideZone: false, confident: true,
        announcement: "Mapped camera ahead"), unit: .kilometersPerHour, cached: false, stale: false).padding()
}

#Preview("Camera · detail card") {
    CameraDetailCard(camera: CameraRecord(id: "demo", coordinate: GeoPoint(latitude: 52, longitude: 5),
        kind: "fixed", name: "A2", maxSpeedKph: 100, directionDegrees: 45, roadRef: "A2",
        association: "relation", sourceIDs: ["osm:node:1"], status: "mapped", routeMatch: "confirmed"),
        unit: .kilometersPerHour, close: {}).padding()
}
