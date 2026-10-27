import SwiftUI

@main
struct RoadScoutApp: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--search-preview") {
                PlaceSearchFlowPreview()
            } else if ProcessInfo.processInfo.arguments.contains("--camera-warning-preview") {
                CameraDrivingPreview()
            } else if ProcessInfo.processInfo.arguments.contains("--average-zone-preview") {
                CameraDrivingPreview(averageZone: true)
            } else if ProcessInfo.processInfo.arguments.contains("--camera-cluster-preview") {
                CameraDrivingPreview(cluster: true)
            } else if ProcessInfo.processInfo.arguments.contains("--camera-detail-preview") {
                CameraDrivingPreview(detail: true)
            } else if ProcessInfo.processInfo.arguments.contains("--driving-dashboard-preview") {
                ContentView.navigationDashboardPreview(
                    unavailableSpeed: ProcessInfo.processInfo.arguments.contains("--missing-speed"),
                    panned: ProcessInfo.processInfo.arguments.contains("--panned"))
            } else if ProcessInfo.processInfo.arguments.contains("--live-scenic-preview") {
                PlaceSearchFlowPreview(showDestination: true, profile: .scenic, liveRouting: true)
            } else if ProcessInfo.processInfo.arguments.contains("--live-corners-preview") {
                PlaceSearchFlowPreview(showDestination: true, profile: .moreCorners, liveRouting: true)
            } else if ProcessInfo.processInfo.arguments.contains("--origin-search-preview") {
                PlaceSearchFlowPreview(showDestination: true, editingOrigin: true)
            } else if ProcessInfo.processInfo.arguments.contains("--custom-origin-preview") {
                PlaceSearchFlowPreview(showDestination: true, customOrigin: true)
            } else if ProcessInfo.processInfo.arguments.contains("--destination-preview") || ProcessInfo.processInfo.arguments.contains("--route-preview") {
                PlaceSearchFlowPreview(showDestination: true)
            } else {
                ContentView()
            }
            #else
            ContentView()
            #endif
        }
    }
}
