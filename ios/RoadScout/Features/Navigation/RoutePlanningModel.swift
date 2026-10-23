import Foundation
import Observation

enum RoutePlanningOrigin: Equatable {
    case myLocation
    case place(Destination)
}

/// Add profiles only when the routing engine/API can actually calculate them.
enum RoutePlanningProfile: String, CaseIterable, Identifiable {
    case fastest
    var id: Self { self }
    var title: String { String(localized: "Fastest") }
}

@MainActor @Observable final class RoutePlanningModel {
    var origin: RoutePlanningOrigin = .myLocation
    var profile: RoutePlanningProfile = .fastest
    var isEditingOrigin = false
    @ObservationIgnored private var lastRequest: RequestKey?

    var originTitle: String {
        switch origin {
        case .myLocation: String(localized: "My location")
        case .place(let place): place.name
        }
    }

    var customOrigin: Destination? {
        if case .place(let place) = origin { return place }
        return nil
    }

    func resolvedOrigin(currentLocation: GeoPoint?) -> GeoPoint? {
        let point = customOrigin?.point ?? currentLocation
        return point.flatMap { $0.isValid ? $0 : nil }
    }

    func preview(_ destination: Destination, currentLocation: GeoPoint?, navigation: NavigationModel,
                 endpoint: String, preferences: RoutePreferences, force: Bool = false) {
        let point = resolvedOrigin(currentLocation: currentLocation)
        let key = RequestKey(origin: point, destination: destination, preferences: preferences, profile: profile)
        if !force, key == lastRequest, navigation.isLoading || navigation.selectedRoute != nil { return }
        lastRequest = key
        navigation.preview(destination, origin: point, endpoint: endpoint, preferences: preferences)
    }

    func reset() {
        origin = .myLocation
        profile = .fastest
        isEditingOrigin = false
        lastRequest = nil
    }

    private struct RequestKey: Equatable {
        let origin: GeoPoint?
        let destination: Destination
        let preferences: RoutePreferences
        let profile: RoutePlanningProfile
    }
}
