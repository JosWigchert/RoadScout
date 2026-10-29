import MapKit
import SwiftUI

struct RouteMapContent: MapContent {
    let geometry: RouteProgressGeometry

    @MapContentBuilder var body: some MapContent {
        if geometry.completed.count >= 2 {
            MapPolyline(coordinates: geometry.completed.map(\.coordinate))
                .stroke(.gray.opacity(0.4), lineWidth: 6)
        }
        if geometry.remaining.count >= 2 {
            MapPolyline(coordinates: geometry.remaining.map(\.coordinate))
                .stroke(.white.opacity(0.8), lineWidth: 9)
            MapPolyline(coordinates: geometry.remaining.map(\.coordinate))
                .stroke(.blue, lineWidth: 6)
        }
    }
}
