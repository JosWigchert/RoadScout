import MapKit
import SwiftUI

struct TrafficDisplayFeature: Identifiable {
    let feature: TrafficFeature
    let points: [GeoPoint]
    var id: String { feature.id }
    static func make(_ features: [TrafficFeature], route: DrivingRoute?, center: GeoPoint? = nil) -> [TrafficDisplayFeature] {
        // Quantize selection priority too: tiny pans must not swap lines at the render budget.
        let center = center.map { GeoPoint(latitude: ($0.latitude * 20).rounded() / 20,
                                          longitude: ($0.longitude * 20).rounded() / 20) }
        let ordered = features.sorted { a, b in
            if (a.routeStartMeters != nil) != (b.routeStartMeters != nil) { return a.routeStartMeters != nil }
            if let center, let ap = a.points.first, let bp = b.points.first {
                let aDistance = ap.distance(to: center), bDistance = bp.distance(to: center)
                if aDistance != bDistance { return aDistance < bDistance }
            }
            return a.id < b.id
        }
        let prepared = ordered.compactMap { f -> TrafficDisplayFeature? in
            if f.kind == "flow", !f.matched || (f.congestion != "slow" && f.congestion != "heavy") { return nil }
            if f.kind == "flow", let route, let start = f.routeStartMeters, let end = f.routeEndMeters {
                guard start < end else { return nil }
                guard let first = RouteProgressGeometry(route: route, traveledMeters: start).remaining.first,
                      let last = RouteProgressGeometry(route: route, traveledMeters: end).completed.last else { return nil }
                var points = [first]
                for (index, point) in route.geometry.enumerated() where route.cumulativeMeters[index] > start && route.cumulativeMeters[index] < end { points.append(point) }
                points.append(last)
                return TrafficDisplayFeature(feature: f, points: points)
            }
            return TrafficDisplayFeature(feature: f, points: f.points)
        }
        var lines = 0, events = 0, points = 0
        let limited = prepared.filter { item in
            if item.feature.kind == "flow" {
                guard lines < 600, points + item.points.count <= 40_000 else { return false }
                lines += 1; points += item.points.count
            } else { guard events < 80 else { return false }; events += 1 }
            return true
        }
        return limited.sorted { $0.id < $1.id }
    }
}

struct TrafficFlowMapContent: MapContent {
    let features: [TrafficDisplayFeature]
    var lineWidth: CGFloat = 5

    @MapContentBuilder var body: some MapContent {
        ForEach(features.sorted { $0.id < $1.id }) { display in
            let feature = display.feature
            if feature.kind == "flow", feature.matched, display.points.count >= 2,
               feature.congestion == "slow" || feature.congestion == "heavy" {
                MapPolyline(coordinates: display.points.map(\.coordinate))
                    .stroke(feature.congestion == "heavy" ? .red : .yellow,
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

struct ClosureMapContent: MapContent {
    let features: [TrafficDisplayFeature]
    let showIcons: Bool
    var lineWidth: CGFloat = 3
    let select: (TrafficFeature) -> Void

    @MapContentBuilder var body: some MapContent {
        ForEach(features) { display in
            let endpoints = RoadClosurePresentation.endpoints(for: display)
            if display.points.count >= 2 {
                MapPolyline(coordinates: display.points.map(\.coordinate))
                    .stroke(Color(red: 0.65, green: 0.06, blue: 0.17),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt, lineJoin: .round,
                                               dash: [6, 5]))
            }
            if showIcons {
                ForEach(Array(endpoints.enumerated()), id: \.offset) { _, point in
                    Annotation(String(localized: "Road closure"), coordinate: point.coordinate) {
                        Button { select(display.feature) } label: {
                            ClosureEndpointMarker()
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(display.feature.title)
                        .accessibilityHint("Shows closure details")
                    }
                    .annotationTitles(.hidden)
                }
            }
        }
    }
}

enum RoadClosurePresentation {
    static func endpoints(for display: TrafficDisplayFeature) -> [GeoPoint] {
        guard display.feature.kind == "closure", let first = display.points.first else { return [] }
        guard let last = display.points.last, display.points.count > 1, first.distance(to: last) > 1 else {
            return [first]
        }
        return [first, last]
    }
}

struct TrafficEventMarker: View {
    let kind: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(foreground)
            .frame(width: 23, height: 23)
            .background(color, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.95), lineWidth: 3))
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
    }

    private var symbol: String {
        switch kind {
        case "closure": "nosign"
        case "roadworks": "figure.construction"
        default: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch kind {
        case "closure": .red
        case "congestion": .yellow
        default: .orange
        }
    }

    private var foreground: Color {
        kind == "congestion" ? .black : .white
    }
}

struct ClosureEndpointMarker: View {
    var body: some View {
        Image(systemName: "nosign")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(.red, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.95), lineWidth: 2.5))
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
    }
}

struct TrafficOfferCard: View {
    let offer: TrafficOffer
    let accept: () -> Void
    let reject: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Faster route · save \(max(2, Int(offer.savingSeconds / 60))) min").font(.headline)
            HStack(spacing: 12) {
                TimelineView(.animation(minimumInterval: 0.1)) { _ in
                    let remaining = max(0, offer.deadline - ProcessInfo.processInfo.systemUptime)
                    Button(action: accept) {
                        HStack {
                            Text("Yes · \(Int(ceil(remaining)))s")
                            ProgressView(value: remaining, total: 15).frame(width: 60)
                        }.frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.borderedProminent)
                     .accessibilityLabel("Switch to the faster route")
                }
                Button("No", action: reject).frame(minWidth: 70, minHeight: 44).buttonStyle(.bordered)
            }
            Text("Switches automatically when the countdown ends.").font(.caption).foregroundStyle(.secondary)
        }.padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
    }
}

struct TrafficRouteLabel: View {
    let traffic: RouteTrafficMetadata
    var body: some View {
        if traffic.isLive, traffic.expiresAt.map({ $0 > Date() }) == true {
            Text(traffic.coveragePercent > 0 ? "Live traffic · \(Int(traffic.coveragePercent.rounded()))% road coverage" : "No traffic data on this route")
                .font(.caption).foregroundStyle(.secondary)
        } else if traffic.isLive {
            Text("Traffic estimate expired · recalculate").font(.caption).foregroundStyle(.secondary)
        } else {
            Text("Traffic routing unavailable").font(.caption).foregroundStyle(.secondary)
        }
    }
}
