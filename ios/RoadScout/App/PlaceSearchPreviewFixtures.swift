#if DEBUG
import MapKit
import SwiftUI

private enum SearchPreviewData {
    static let origin = GeoPoint(latitude: 52.091, longitude: 5.12)
    static let places = [
        Destination(name: "Market at the Canal", address: "Canal Street 24, Utrecht",
                    category: MKPointOfInterestCategory.foodMarket.rawValue, symbol: "cart.fill",
                    coordinate: GeoPoint(latitude: 52.102, longitude: 5.118)),
        Destination(name: "Neighbourhood Market", address: "Market Street 12, Utrecht",
                    category: MKPointOfInterestCategory.foodMarket.rawValue, symbol: "cart.fill",
                    coordinate: GeoPoint(latitude: 52.094, longitude: 5.125),
                    website: URL(string: "https://example.com")),
        Destination(name: "City Market", address: "Station Square 8, Utrecht",
                    category: MKPointOfInterestCategory.foodMarket.rawValue, symbol: "cart.fill",
                    coordinate: GeoPoint(latitude: 52.13, longitude: 5.15)),
        Destination(name: "Market Square", address: "High Street 36, Utrecht",
                    category: MKPointOfInterestCategory.foodMarket.rawValue, symbol: "cart.fill",
                    coordinate: GeoPoint(latitude: 52.20, longitude: 5.11))
    ]
}

@MainActor private struct PreviewPlaceSearch: PlaceSearching {
    func search(_ query: String, near: GeoPoint?) async throws -> [Destination] {
        SearchPreviewData.places
    }
}

private struct PreviewPlaceRouting: RoutingProviding {
    func routes(for request: RouteRequest) async throws -> [DrivingRoute] {
        let origin = request.origin
        let destination = request.destination
        guard origin.distance(to: destination) > 5 else { throw RoutingError.noRoute }
        return try [0.0, 0.004].map { offset in
            let longitude = (origin.longitude + destination.longitude) / 2 + offset
            let shape = [origin,
                         GeoPoint(latitude: origin.latitude + offset, longitude: longitude),
                         GeoPoint(latitude: destination.latitude, longitude: longitude), destination]
            let distance = zip(shape, shape.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
            let seconds = max(120, distance / 11) + (offset == 0 ? 0 : 180)
            return try DrivingRoute(geometry: shape, distanceMeters: distance, durationSeconds: seconds,
                maneuvers: [RouteManeuver(id: "depart", instruction: "Follow the synthetic preview route", spokenInstruction: "Synthetic route",
                                         beginIndex: 0, endIndex: 2, seconds: seconds, type: "depart", modifier: "straight",
                                         streetNames: [offset == 0 ? "Demo avenue" : "Demo parkway"], distanceMeters: distance),
                            RouteManeuver(id: "arrive", instruction: "Synthetic destination", spokenInstruction: "Synthetic destination",
                                         beginIndex: 3, endIndex: 3, seconds: 0, type: "arrive", modifier: "")],
                attribution: "Synthetic preview geometry · not a verified road route")
        }
    }
}

@MainActor private final class SearchPreviewLocation: LocationProviding {
    var onEvent: ((LocationEvent) -> Void)?
    let timestamp: Date
    init(timestamp: Date) { self.timestamp = timestamp }
    func start() {
        onEvent?(.fix(LocationFix(latitude: SearchPreviewData.origin.latitude, longitude: SearchPreviewData.origin.longitude,
                                 speed: 0, speedAccuracy: 0.5, horizontalAccuracy: 5, course: 0, timestamp: timestamp)))
    }
    func stop() { }
}

/// Synthetic search/location with optional real LAN routing; never requests GPS permission.
struct PlaceSearchFlowPreview: View {
    let showDestination: Bool
    let liveRouting: Bool
    let previewDestination: Destination
    @State private var search: PlaceSearchModel
    @State private var location: PlanningLocationModel
    @State private var driving: DrivingModel
    @State private var navigation: NavigationModel
    @State private var planner: RoutePlanningModel
    @State private var originSearch: PlaceSearchModel

    init(showDestination: Bool = false, editingOrigin: Bool = false, customOrigin: Bool = false,
         profile: RoutePlanningProfile = .fastest, liveRouting: Bool = false) {
        self.showDestination = showDestination
        self.liveRouting = liveRouting
        previewDestination = liveRouting ? Destination(name: "Amersfoort", point: GeoPoint(latitude: 52.1552, longitude: 5.3872)) : SearchPreviewData.places[2]
        let now = Date()
        let recents = PlaceRecents(userDefaults: UserDefaults(suiteName: "RoadScout.SearchPreviews")!)
        let search = PlaceSearchModel(service: PreviewPlaceSearch(), recents: recents,
                                      enableCompleter: false, debounce: .zero)
        search.query = "market"
        _search = State(initialValue: search)
        _location = State(initialValue: PlanningLocationModel(provider: SearchPreviewLocation(timestamp: now), now: { now }))
        _driving = State(initialValue: DrivingModel(makeProvider: { _ in SearchPreviewLocation(timestamp: now) }, now: { now }))
        _navigation = State(initialValue: NavigationModel(provider: { endpoint in
            if liveRouting { return try RoadScoutRoutingProvider(baseURL: endpoint) }
            return PreviewPlaceRouting()
        }))
        let planner = RoutePlanningModel()
        planner.apply(options: PlaceSearchFlowPreview.previewOptions)
        planner.profile = profile
        planner.isEditingOrigin = editingOrigin
        if customOrigin { planner.origin = .place(SearchPreviewData.places[0]) }
        _planner = State(initialValue: planner)
        let originSearch = PlaceSearchModel(service: PreviewPlaceSearch(), recents: recents, enableCompleter: false, debounce: .zero)
        if editingOrigin { originSearch.query = "market" }
        _originSearch = State(initialValue: originSearch)
    }

    static let previewOptions: [RouteOption] = [
        .fastest,
        RouteOption(id: "scenic", title: "Scenic", isExperimental: true, detourOptions: RouteOption.defaultDetourOptions),
        RouteOption(id: "more_corners", title: "More Corners", isExperimental: true, detourOptions: RouteOption.defaultDetourOptions)
    ]

    var body: some View {
        ContentView(model: driving, initialDrawerDetent: .medium, searchModel: search,
                    planningLocation: location, initialDestination: showDestination ? previewDestination : nil,
                    navigationModel: navigation, routePlanner: planner, originSearchModel: originSearch,
                    routeCatalog: RoutingCatalog(options: PlaceSearchFlowPreview.previewOptions))
            .task {
                location.request()
                if !showDestination { search.search(near: SearchPreviewData.origin) }
                if showDestination {
                    planner.preview(previewDestination, currentLocation: SearchPreviewData.origin,
                                    navigation: navigation, endpoint: AppConfiguration.routingAPIBaseURL, preferences: .init())
                }
                if planner.isEditingOrigin { originSearch.search(near: SearchPreviewData.origin) }
            }
            .defaultAppStorage(UserDefaults(suiteName: "RoadScout.SearchPreviews")!)
    }
}

#Preview("Search · nearest places") { PlaceSearchFlowPreview() }
#Preview("Search · destination on map") { PlaceSearchFlowPreview(showDestination: true) }
#Preview("Search · destination · dark") {
    PlaceSearchFlowPreview(showDestination: true).preferredColorScheme(.dark)
}
#Preview("Directions · custom origin") { PlaceSearchFlowPreview(showDestination: true, customOrigin: true) }
#Preview("Directions · starting point search") { PlaceSearchFlowPreview(showDestination: true, editingOrigin: true) }
#Preview("Directions · landscape", traits: .landscapeLeft) { PlaceSearchFlowPreview(showDestination: true) }
#Preview("Scenic · live LAN API, synthetic origin") { PlaceSearchFlowPreview(showDestination: true, profile: .scenic, liveRouting: true) }
#Preview("Corners · live LAN API, synthetic origin") { PlaceSearchFlowPreview(showDestination: true, profile: .moreCorners, liveRouting: true) }
#endif
