import MapKit
import SwiftUI

struct MapTrafficLayers: MapContent {
    let routeGeometry: RouteProgressGeometry?
    let flowFeatures: [TrafficDisplayFeature]
    let closureFeatures: [TrafficDisplayFeature]
    let cameras: [CameraRecord]
    let events: [TrafficFeature]
    let zones: [AverageSpeedZone]
    let bounds: CameraBounds?
    let selectCamera: (CameraRecord) -> Void
    let selectTraffic: (TrafficFeature) -> Void
    let selectCluster: (CameraBounds) -> Void

    @MapContentBuilder var body: some MapContent {
        if let routeGeometry {
            RouteMapContent(geometry: routeGeometry)
        }
        TrafficFlowMapContent(features: flowFeatures, lineWidth: MapDisplayScale.flowWidth(in: bounds))
        ClosureMapContent(features: closureFeatures,
                          showIcons: MapDisplayScale.showsClosureEndpoints(in: bounds),
                          lineWidth: MapDisplayScale.closureWidth(in: bounds),
                          select: selectTraffic)
        if !cameras.isEmpty || !events.isEmpty || !zones.isEmpty {
            MapOverlayContent(cameras: cameras, events: events, zones: zones, bounds: bounds,
                              selectCamera: selectCamera, selectEvent: selectTraffic,
                              selectCluster: selectCluster)
        }
    }
}

enum MapDisplayScale {
    static func flowWidth(in bounds: CameraBounds?) -> CGFloat {
        guard let bounds else { return 5 }
        switch max(bounds.north - bounds.south, bounds.east - bounds.west) {
        case ..<0.05: return 5
        case ..<0.2: return 3.5
        case ..<0.8: return 2.5
        default: return 1.5
        }
    }

    static func closureWidth(in bounds: CameraBounds?) -> CGFloat {
        max(1.5, flowWidth(in: bounds) * 0.65)
    }

    static func showsClosureEndpoints(in bounds: CameraBounds?) -> Bool {
        guard let bounds else { return true }
        return max(bounds.north - bounds.south, bounds.east - bounds.west) <= 0.12
    }
}
