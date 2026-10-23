import SwiftUI

@main
struct RoadScoutApp: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--search-preview") {
                PlaceSearchFlowPreview()
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
