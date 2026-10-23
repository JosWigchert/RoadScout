import Foundation
import MapKit
import Observation

private enum PlaceSearchConfiguration {
    static let regionMeters: Double = 50_000
    static let resultLimit = 30
}

@MainActor protocol PlaceSearching {
    func search(_ query: String, near: GeoPoint?) async throws -> [Destination]
}

@MainActor final class MapKitPlaceSearch: PlaceSearching {
    private var searches: [UUID: MKLocalSearch] = [:]
    private func cancel(_ id: UUID) { searches[id]?.cancel() }

    func search(_ query: String, near: GeoPoint?) async throws -> [Destination] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.address, .pointOfInterest]
        if let near { request.region = MKCoordinateRegion(center: near.coordinate, latitudinalMeters: PlaceSearchConfiguration.regionMeters, longitudinalMeters: PlaceSearchConfiguration.regionMeters) }
        let search = MKLocalSearch(request: request)
        let id = UUID()
        searches[id] = search
        defer { searches[id] = nil }
        let response = try await withTaskCancellationHandler { try await search.start() } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
        try Task.checkCancellation()
        return response.mapItems.map { Self.destination(for: $0, near: near) }
    }

    static func destination(for item: MKMapItem, near: GeoPoint?) -> Destination {
        let coordinate = item.placemark.coordinate
        let distance = near.map { GeoPoint(latitude: coordinate.latitude, longitude: coordinate.longitude).distance(to: $0) }
        return SearchResult(name: item.name ?? String(localized: "Destination"),
                                address: item.placemark.title,
                                locality: item.placemark.locality,
                                category: item.pointOfInterestCategory?.rawValue,
                                symbol: MapKitPlaceSearch.symbol(for: item.pointOfInterestCategory),
                                distance: distance,
                                coordinate: coordinate,
                                phoneNumber: item.phoneNumber, website: item.url)
    }

    static func symbol(for category: MKPointOfInterestCategory?) -> String? {
        switch category {
        case .cafe: return "cup.and.saucer.fill"
        case .restaurant: return "fork.knife"
        case .hotel: return "bed.double.fill"
        case .airport: return "airplane"
        case .gasStation: return "fuelpump.fill"
        case .hospital: return "cross.fill"
        case .pharmacy: return "pills.fill"
        case .park: return "leaf.fill"
        case .museum: return "building.columns.fill"
        case .store, .foodMarket: return "cart.fill"
        case .bakery: return "birthday.cake.fill"
        case .bank: return "banknote.fill"
        case .parking: return "parkingsign.circle.fill"
        case .publicTransport: return "tram.fill"
        case .library: return "books.vertical.fill"
        case .school: return "graduationcap.fill"
        case .university: return "building.fill"
        case .postOffice: return "envelope.fill"
        case .police: return "shield.fill"
        case .fireStation: return "flame.fill"
        case .theater: return "theatermasks.fill"
        case .stadium: return "sportscourt.fill"
        case .zoo: return "pawprint.fill"
        case .aquarium: return "fish.fill"
        case .amusementPark: return "ticket.fill"
        case .campground: return "tent.fill"
        case .nationalPark: return "mountain.2.fill"
        case .beach: return "beach.umbrella.fill"
        case .marina: return "sailboat.fill"
        case .evCharger: return "bolt.car.fill"
        default: return nil
        }
    }
}

@MainActor @Observable final class PlaceSearchModel {
    var query = ""
    private(set) var results: [Destination] = []
    private(set) var isLoading = false
    private(set) var message: String?
    private(set) var completions: [MKLocalSearchCompletion] = []
    private(set) var selectedDestination: Destination?
    var sortOrder: PlaceSortOrder = .nearest { didSet { refreshDistances() } }
    @ObservationIgnored private(set) var recentsStore: PlaceRecents
    @ObservationIgnored private let service: any PlaceSearching
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let completer: MKLocalSearchCompleter?
    @ObservationIgnored private var completerDelegate: CompleterDelegate?
    @ObservationIgnored private var debounce: TimeInterval
    @ObservationIgnored private var completerRegion: MKCoordinateRegion?
    @ObservationIgnored private var providerResults: [Destination] = []
    @ObservationIgnored private var origin: GeoPoint?
    @ObservationIgnored private var resolutionSearches: [UUID: MKLocalSearch] = [:]

    var recents: PlaceRecents { recentsStore }
    var debounceInterval: TimeInterval { debounce }
    var localSearchCompleter: MKLocalSearchCompleter? { completer }

    var searchStatus: String {
        if isLoading { return String(localized: "Searching places…") }
        if let message, !message.isEmpty { return message }
        if results.isEmpty, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "No places found.")
        }
        if !results.isEmpty { return String(localized: "\(results.count) places found") }
        return String(localized: "Search places")
    }
    var status: String { searchStatus }
    var statusText: String { searchStatus }
    var statusMessage: String { searchStatus }
    var statusLine: String { searchStatus }

    init(service: any PlaceSearching = MapKitPlaceSearch(),
         recents: PlaceRecents? = nil,
         enableCompleter: Bool = true,
         debounce: Duration = .milliseconds(150)) {
        self.service = service
        self.recentsStore = recents ?? PlaceRecents()
        self.debounce = max(0, debounce.timeInterval)
        if enableCompleter {
            let delegate = CompleterDelegate()
            let completer = MKLocalSearchCompleter()
            completer.resultTypes = [.address, .pointOfInterest, .query]
            self.completer = completer
            self.completerDelegate = delegate
            completer.delegate = delegate
            delegate.owner = self
        } else {
            self.completer = nil
            self.completerDelegate = nil
        }
    }

    func search(near: GeoPoint?, searchCenter: GeoPoint? = nil) {
        cancel()
        origin = near
        selectedDestination = nil
        providerResults = []
        results = []
        message = nil
        completions = []
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { isLoading = false; return }
        isLoading = true
        let token = generation
        if let completer {
            if let center = near ?? searchCenter { completer.region = MKCoordinateRegion(center: center.coordinate, latitudinalMeters: PlaceSearchConfiguration.regionMeters, longitudinalMeters: PlaceSearchConfiguration.regionMeters) }
            completer.queryFragment = text
        }
        task = Task { [weak self, service] in
            if let delay = self?.debounce, delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            try? Task.checkCancellation()
            guard let self, generation == token else { return }
            do {
                let values = try await service.search(text, near: near ?? searchCenter)
                try? Task.checkCancellation()
                guard generation == token else { return }
                providerResults = values
                refreshDistances()
                isLoading = false
                if values.isEmpty { message = String(localized: "No places found. Try another search.") }
            } catch {
                guard generation == token else { return }
                isLoading = false
                if !(error is CancellationError) { message = String(localized: "Place search unavailable. Try again.") }
            }
        }
    }

    func updateOrigin(_ origin: GeoPoint?) {
        self.origin = origin
        refreshDistances()
    }

    private func refreshDistances() {
        results = Array(PlaceProximity.updated(providerResults, origin: origin, order: sortOrder)
            .prefix(PlaceSearchConfiguration.resultLimit))
    }

    func search(_ query: String, near: GeoPoint?) {
        self.query = query
        search(near: near)
    }

    func updateQuery(_ text: String, near: GeoPoint? = nil) {
        query = text
        search(near: near)
    }

    func updateCompletions(near: GeoPoint? = nil) {
        guard let completer else { return }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        completer.queryFragment = text
        if let near { completer.region = MKCoordinateRegion(center: near.coordinate, latitudinalMeters: PlaceSearchConfiguration.regionMeters, longitudinalMeters: PlaceSearchConfiguration.regionMeters) }
    }

    func setCompletions(_ values: [MKLocalSearchCompletion]) {
        guard selectedDestination == nil, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        completions = Array(values.prefix(3))
    }

    func resolve(_ completion: MKLocalSearchCompletion, near: GeoPoint?) async -> Destination? {
        let request = MKLocalSearch.Request(completion: completion)
        if let near { request.region = MKCoordinateRegion(center: near.coordinate, latitudinalMeters: PlaceSearchConfiguration.regionMeters, longitudinalMeters: PlaceSearchConfiguration.regionMeters) }
        let search = MKLocalSearch(request: request)
        let id = UUID()
        resolutionSearches[id] = search
        defer { resolutionSearches[id] = nil }
        do {
            let response = try await withTaskCancellationHandler { try await search.start() } onCancel: {
                Task { @MainActor in self.cancelResolution(id) }
            }
            try Task.checkCancellation()
            guard let item = response.mapItems.first else { return nil }
            return MapKitPlaceSearch.destination(for: item, near: near)
        } catch {
            return nil
        }
    }

    func resolveCompletion(_ completion: MKLocalSearchCompletion, near: GeoPoint?) async -> Destination? {
        await resolve(completion, near: near)
    }

    func selectCompletion(_ completion: MKLocalSearchCompletion, near: GeoPoint? = nil, searchCenter: GeoPoint? = nil) {
        cancel()
        isLoading = true
        selectedDestination = nil
        message = nil
        let token = generation
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            let destination = await self.resolve(completion, near: near ?? searchCenter)
            guard self.generation == token else { return }
            self.isLoading = false
            if let destination {
                if self.providerResults.isEmpty {
                    self.providerResults = [destination]
                    self.refreshDistances()
                }
                self.select(destination)
            } else {
                self.message = String(localized: "No places found. Try another search.")
            }
        }
    }

    func selectSuggestion(_ completion: MKLocalSearchCompletion, near: GeoPoint? = nil) {
        selectCompletion(completion, near: near)
    }

    func search(_ completion: MKLocalSearchCompletion, near: GeoPoint?) {
        selectCompletion(completion, near: near)
    }

    func search(completion: MKLocalSearchCompletion, near: GeoPoint?) {
        selectCompletion(completion, near: near)
    }

    func searchCompletion(_ completion: MKLocalSearchCompletion, near: GeoPoint?) {
        selectCompletion(completion, near: near)
    }

    func cancel() {
        generation = UUID(); task?.cancel(); task = nil; isLoading = false; completions = []
        completer?.cancel()
        resolutionSearches.values.forEach { $0.cancel() }
    }

    private func cancelResolution(_ id: UUID) { resolutionSearches[id]?.cancel() }

    func select(_ destination: Destination) {
        cancel()
        selectedDestination = destination
        recentsStore.add(destination)
    }

    func clearSelection() { selectedDestination = nil }

    func addRecent(_ destination: Destination) { recentsStore.add(destination) }
    func removeRecent(_ destination: Destination) { recentsStore.remove(destination) }
    func clearRecents() { recentsStore.clear() }

    deinit { task?.cancel() }
}

@MainActor private final class CompleterDelegate: NSObject, @preconcurrency MKLocalSearchCompleterDelegate {
    weak var owner: PlaceSearchModel?

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        owner?.setCompletions(completer.results)
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        owner?.setCompletions([])
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
