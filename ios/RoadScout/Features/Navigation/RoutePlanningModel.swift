import Foundation
import Observation

enum RoutePlanningOrigin: Equatable {
    case myLocation
    case place(Destination)
}

/// Routing styles are identified by the server's raw value. Keeping this a
/// value type lets the app use new Go-defined styles without a rebuild.
struct RoutePlanningProfile: Hashable, Identifiable, Sendable {
    let rawValue: String
    var id: String { rawValue }
    init(rawValue: String) { self.rawValue = rawValue }
    static let fastest = Self(rawValue: "fastest")
    static let scenic = Self(rawValue: "scenic")
    static let moreCorners = Self(rawValue: "more_corners")
    var isExperimental: Bool { rawValue != "fastest" }
    var fallbackTitle: String { RouteOption.defaultTitle(rawValue) }
}

@MainActor @Observable final class RoutePlanningModel {
    private enum Keys {
        static let profile = "routePlanningProfile"
        static let budget = "routePlanningDetourPercent"
    }

    var origin: RoutePlanningOrigin = .myLocation
    var profile: RoutePlanningProfile = .fastest {
        didSet {
            defaults?.set(profile.rawValue, forKey: Keys.profile)
            clampBudget()
        }
    }
    var maxExtraDurationPercent = 30 {
        didSet { defaults?.set(maxExtraDurationPercent, forKey: Keys.budget) }
    }
    var isEditingOrigin = false
    private(set) var options: [RouteOption] = [.fastest]
    @ObservationIgnored private var lastRequest: RequestKey?
    @ObservationIgnored private let defaults: UserDefaults?

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        if let raw = defaults?.string(forKey: Keys.profile), !raw.isEmpty {
            profile = RoutePlanningProfile(rawValue: raw)
        }
        if let saved = defaults?.object(forKey: Keys.budget) as? Int {
            maxExtraDurationPercent = saved
        }
    }

    var selectedOption: RouteOption? { options.first { $0.id == profile.rawValue } }
    var detourOptions: [Int] { selectedOption?.detourOptions ?? [] }
    var canChooseStyle: Bool { options.count > 1 }
    var usesDetourBudget: Bool { !detourOptions.isEmpty }

    func applyCatalog(_ catalog: RoutingCatalog, includeExperimental: Bool) {
        apply(options: catalog.visibleOptions(includeExperimental: includeExperimental))
    }

    func apply(options: [RouteOption]) {
        self.options = options.isEmpty ? [.fastest] : options
        if !self.options.contains(where: { $0.id == profile.rawValue }) { profile = .fastest }
        clampBudget()
    }

    private func clampBudget() {
        let allowed = detourOptions
        guard !allowed.isEmpty, !allowed.contains(maxExtraDurationPercent) else { return }
        maxExtraDurationPercent = allowed.first ?? 30
    }

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
        let key = RequestKey(origin: point, destination: destination, preferences: preferences, profile: profile, budget: maxExtraDurationPercent, endpoint: endpoint)
        if !force, key == lastRequest, navigation.isLoading || navigation.selectedRoute != nil { return }
        lastRequest = key
        navigation.preview(destination, origin: point, endpoint: endpoint, preferences: preferences,
                           objective: profile, maxExtraDurationPercent: maxExtraDurationPercent)
    }

    func clearTrip() {
        origin = .myLocation
        isEditingOrigin = false
        lastRequest = nil
    }

    func reset() {
        clearTrip()
        profile = .fastest
        maxExtraDurationPercent = 30
    }

    private struct RequestKey: Equatable {
        let origin: GeoPoint?
        let destination: Destination
        let preferences: RoutePreferences
        let profile: RoutePlanningProfile
        let budget: Int
        let endpoint: String
    }
}
