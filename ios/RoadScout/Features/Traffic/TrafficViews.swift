import MapKit
import SwiftUI

struct TrafficDisplayFeature: Identifiable {
    let feature: TrafficFeature
    let points: [GeoPoint]
    var id: String { feature.id }
    static func make(_ features: [TrafficFeature], route: DrivingRoute?, traveled: Double, center: GeoPoint? = nil) -> [TrafficDisplayFeature] {
        let ordered = features.sorted { a, b in
            if (a.routeStartMeters != nil) != (b.routeStartMeters != nil) { return a.routeStartMeters != nil }
            if let center, let ap = a.points.first, let bp = b.points.first { return ap.distance(to: center) < bp.distance(to: center) }
            return a.id < b.id
        }
        let prepared = ordered.compactMap { f -> TrafficDisplayFeature? in
            if f.kind == "flow", !f.matched || (f.congestion != "slow" && f.congestion != "heavy") { return nil }
            if f.kind == "flow", let route, let start = f.routeStartMeters, let end = f.routeEndMeters {
                let begin = max(start, traveled)
                guard begin < end else { return nil }
                guard let first = RouteProgressGeometry(route: route, traveledMeters: begin).remaining.first,
                      let last = RouteProgressGeometry(route: route, traveledMeters: end).completed.last else { return nil }
                var points = [first]
                for (index, point) in route.geometry.enumerated() where route.cumulativeMeters[index] > begin && route.cumulativeMeters[index] < end { points.append(point) }
                points.append(last)
                return TrafficDisplayFeature(feature: f, points: points)
            }
            return TrafficDisplayFeature(feature: f, points: f.points)
        }
        var lines = 0, events = 0, points = 0
        return prepared.filter { item in
            if item.feature.kind == "flow" {
                guard lines < 160, points + item.points.count <= 20_000 else { return false }
                lines += 1; points += item.points.count
            } else { guard events < 80 else { return false }; events += 1 }
            return true
        }
    }
}

struct TrafficMapContent: MapContent {
    let features: [TrafficDisplayFeature]
    let select: (TrafficFeature) -> Void
    @MapContentBuilder var body: some MapContent {
        ForEach(features) { display in
            let feature = display.feature
            if feature.kind == "flow", feature.matched, display.points.count >= 2,
               feature.congestion == "slow" || feature.congestion == "heavy" {
                MapPolyline(coordinates: display.points.map(\.coordinate))
                    .stroke(feature.congestion == "heavy" ? .red : .orange, lineWidth: 6)
            } else if feature.kind != "flow", let point = display.points.first {
                Annotation(feature.title, coordinate: point.coordinate) {
                    Button { select(feature) } label: {
                        Image(systemName: feature.kind == "closure" ? "nosign" : (feature.kind == "roadworks" ? "figure.construction" : "exclamationmark.triangle.fill"))
                            .font(.caption.bold()).foregroundStyle(.white).padding(8)
                            .background(feature.kind == "closure" ? Color.red : .orange, in: Circle())
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                    }.buttonStyle(.plain).accessibilityLabel(feature.title)
                }.annotationTitles(.hidden)
            }
        }
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
