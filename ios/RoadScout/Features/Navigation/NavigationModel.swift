import Foundation
import Observation

@MainActor @Observable final class NavigationModel {
    private(set) var routes: [DrivingRoute] = []
    private(set) var selectedRoute: DrivingRoute?
    private(set) var destination: Destination?
    private(set) var progress: NavigationProgress?
    private(set) var isNavigating = false
    private(set) var isPaused = false
    private(set) var isLoading = false
    private(set) var message: String?
    private(set) var isFreeDriving = false
    var muted = false { didSet { if muted { audio.stop() }; onMuteChanged?(muted) } }
    @ObservationIgnored var onRouteChanged: (() -> Void)?
    @ObservationIgnored var onMuteChanged: ((Bool) -> Void)?
    @ObservationIgnored private var trafficETA: (routeID: String, seconds: Double, elapsed: Double, expires: Date)?

    func applyTrafficETA(routeID: String, seconds: Double, expiresAt: Date) {
        guard selectedRoute?.id == routeID, let route = selectedRoute, let progress,
              seconds.isFinite, seconds >= 0, expiresAt > now() else { return }
        trafficETA = (routeID, seconds, route.elapsedSeconds(at: progress.traveledMeters), expiresAt)
        self.progress = trafficAdjusted(progress)
    }

    private func trafficAdjusted(_ value: NavigationProgress) -> NavigationProgress {
        guard let estimate = trafficETA, let route = selectedRoute, route.id == estimate.routeID,
              estimate.expires > now(), !value.arrived else { return value }
        return NavigationProgress(traveledMeters: value.traveledMeters, remainingMeters: value.remainingMeters,
            remainingSeconds: max(0, estimate.seconds - max(0, route.elapsedSeconds(at: value.traveledMeters) - estimate.elapsed)),
            maneuverIndex: value.maneuverIndex, maneuverDistance: value.maneuverDistance,
            offRoute: value.offRoute, arrived: value.arrived, onRoute: value.onRoute)
    }

    /// A traffic offer has already been revalidated from fresh GPS against its corridor.
    func adoptTrafficAlternative(_ route: DrivingRoute, fix: LocationFix) {
        guard isNavigating, !isPaused, fix.hasUsablePosition(at: now()),
              GeoPoint(latitude: fix.latitude, longitude: fix.longitude).distance(to: route.geometry[0]) <= 50 else { return }
        cancelRequest(); audio.stop(); trafficETA = nil
        routes = [route]; selectedRoute = route; tracker = NavigationTracker(route: route)
        progress = nil; announced = []; lastSpokenAt = nil
        consume(fix); onRouteChanged?()
    }
    @ObservationIgnored private let audio: any AudioAnnouncing
    @ObservationIgnored private let provider: (String) throws -> any RoutingProviding
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var tracker: NavigationTracker?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var token = UUID()
    @ObservationIgnored private var lastReroute: Date?
    @ObservationIgnored private var rerouteDelay: TimeInterval = 15
    @ObservationIgnored private var rerouteInFlight = false
    @ObservationIgnored private var announced: Set<String> = []
    @ObservationIgnored private var lastSpokenAt: Date?
    @ObservationIgnored private var endpoint = ""
    @ObservationIgnored private var preferences = RoutePreferences()
    @ObservationIgnored private var objective: RoutePlanningProfile = .fastest
    @ObservationIgnored private var maxExtraDurationPercent = 30
    @ObservationIgnored private var headingSmoother: HeadingSmoother?

    var isFreeDrive: Bool { isFreeDriving }
    var freeDriving: Bool { isFreeDriving }
    var freeDriveActive: Bool { isFreeDriving }
    var isFreeDrivingMode: Bool { isFreeDriving }
    var smoother: HeadingSmoother? { headingSmoother }
    var headingSmootherValue: HeadingSmoother? { headingSmoother }
    var routePreviewDestination: Destination? { destination }
    var selectedDestination: Destination? { destination }
    var previewDestination: Destination? { destination }

    init(audio: any AudioAnnouncing = SpeechAnnouncer(),
         provider: @escaping (String) throws -> any RoutingProviding = { try RoadScoutRoutingProvider(baseURL: $0) },
         now: @escaping () -> Date = Date.init,
         headingSmoother: HeadingSmoother? = HeadingSmoother(timeConstant: 0.35)) {
        self.audio = audio; self.provider = provider; self.now = now; self.headingSmoother = headingSmoother
    }

    convenience init(audio: any AudioAnnouncing, headingSmoother: HeadingSmoother?) {
        self.init(audio: audio, provider: { try RoadScoutRoutingProvider(baseURL: $0) }, now: Date.init, headingSmoother: headingSmoother)
    }

    convenience init(headingSmoother: HeadingSmoother?) {
        self.init(audio: SpeechAnnouncer(), provider: { try RoadScoutRoutingProvider(baseURL: $0) }, now: Date.init, headingSmoother: headingSmoother)
    }

    convenience init(smoother: HeadingSmoother?) {
        self.init(headingSmoother: smoother)
    }

    func preview(_ destination: Destination, fix: LocationFix?, endpoint: String, preferences: RoutePreferences,
                 objective: RoutePlanningProfile = .fastest, maxExtraDurationPercent: Int = 30) {
        end()
        self.destination = destination; self.endpoint = endpoint; self.preferences = preferences
        self.objective = objective; self.maxExtraDurationPercent = maxExtraDurationPercent
        isFreeDriving = false
        guard let fix, fix.hasUsablePosition(at: now()) else {
            message = String(localized: "Start driving and wait for a fresh GPS position before calculating a route.")
            return
        }
        calculate(fix: fix, rerouting: false)
    }

    /// Planning coordinates may come from search; they are never treated as a live navigation fix.
    func preview(_ destination: Destination, origin: GeoPoint?, endpoint: String, preferences: RoutePreferences,
                 objective: RoutePlanningProfile = .fastest, maxExtraDurationPercent: Int = 30) {
        end()
        self.destination = destination
        self.endpoint = endpoint
        self.preferences = preferences
        self.objective = objective
        self.maxExtraDurationPercent = maxExtraDurationPercent
        guard let origin else {
            message = String(localized: "Choose a starting point or use your location to preview the route.")
            return
        }
        guard origin.isValid, destination.point.isValid else {
            message = RoutingError.noRoute.localizedDescription
            return
        }
        calculate(origin: origin, heading: nil, rerouting: false)
    }

    func refreshFromGPS(_ fix: LocationFix?) {
        guard let destination else { return }
        preview(destination, fix: fix, endpoint: endpoint, preferences: preferences,
                objective: objective, maxExtraDurationPercent: maxExtraDurationPercent)
    }

    func previewRoute(_ destination: Destination, fix: LocationFix?, endpoint: String, preferences: RoutePreferences) {
        preview(destination, fix: fix, endpoint: endpoint, preferences: preferences)
    }

    func previewDestination(_ destination: Destination, fix: LocationFix?, endpoint: String, preferences: RoutePreferences) {
        preview(destination, fix: fix, endpoint: endpoint, preferences: preferences)
    }

    func select(_ route: DrivingRoute) {
        guard !isNavigating, routes.contains(where: { $0.id == route.id }) else { return }
        selectedRoute = route
        if let objective = route.objective { self.objective = objective }
        onRouteChanged?()
    }

    func selectDestination(_ destination: Destination, fix: LocationFix?, endpoint: String, preferences: RoutePreferences) {
        preview(destination, fix: fix, endpoint: endpoint, preferences: preferences)
    }

    func openRoutePreview(_ destination: Destination, fix: LocationFix?, endpoint: String, preferences: RoutePreferences) {
        preview(destination, fix: fix, endpoint: endpoint, preferences: preferences)
    }

    func openRoutePreviewInDrawer(_ destination: Destination, fix: LocationFix?, endpoint: String, preferences: RoutePreferences) {
        preview(destination, fix: fix, endpoint: endpoint, preferences: preferences)
    }

    func selectRoute(_ route: DrivingRoute) { select(route) }

    func start(fix: LocationFix?) {
        guard let route = selectedRoute, let fix, fix.hasUsablePosition(at: now()) else {
            message = String(localized: "A fresh GPS position is required to start or resume navigation.")
            return
        }
        if !isPaused { tracker = NavigationTracker(route: route); announced = [] }
        isNavigating = true; isPaused = false; isFreeDriving = false; message = nil
        if !muted, let departure = route.maneuvers.first, departure.type == "depart",
           !announced.contains("\(route.id)-\(departure.id)"),
           GeoPoint(latitude: fix.latitude, longitude: fix.longitude).distance(to: route.geometry[0]) < 30 {
            announced.insert("\(route.id)-\(departure.id)")
            audio.speak(departure.spokenInstruction, language: route.language); lastSpokenAt = now()
        }
        consume(fix)
    }

    /// Keep a selected alternative when its start still matches GPS; otherwise recalculate from reality.
    @discardableResult
    func startPreviewOrRecalculate(fix: LocationFix?) -> Bool {
        guard let route = selectedRoute, let fix, fix.hasUsablePosition(at: now()) else { return false }
        let point = GeoPoint(latitude: fix.latitude, longitude: fix.longitude)
        guard point.distance(to: route.geometry[0]) <= 50 else {
            refreshFromGPS(fix)
            return false
        }
        start(fix: fix)
        return isNavigating || progress?.arrived == true
    }

    func startFreeDrive(fix: LocationFix? = nil) {
        end()
        isFreeDriving = true
        message = nil
        if let fix, fix.hasUsablePosition(at: now()) {
            // Free drive does not require a destination; keep navigation idle.
        }
    }

    func startFreeDriving(fix: LocationFix? = nil) { startFreeDrive(fix: fix) }
    func beginFreeDrive(fix: LocationFix? = nil) { startFreeDrive(fix: fix) }
    func beginFreeDriving(fix: LocationFix? = nil) { startFreeDrive(fix: fix) }
    func startDrive(fix: LocationFix? = nil) { startFreeDrive(fix: fix) }
    func freeDrive(fix: LocationFix? = nil) { startFreeDrive(fix: fix) }
    func startFreeDriveWithoutDestination(fix: LocationFix? = nil) { startFreeDrive(fix: fix) }
    func startFreeDrivingWithoutDestination(fix: LocationFix? = nil) { startFreeDrive(fix: fix) }

    func stopFreeDrive() { isFreeDriving = false }
    func endFreeDrive() { isFreeDriving = false }

    func pause() {
        cancelRequest()
        guard isNavigating else { return }
        isPaused = true; audio.stop()
        message = String(localized: "Navigation paused. Start driving, then resume with fresh GPS.")
    }

    func end() {
        trafficETA = nil
        cancelRequest(); audio.stop(); isNavigating = false; isPaused = false
        routes = []; selectedRoute = nil; destination = nil; progress = nil; tracker = nil
        message = nil; lastReroute = nil; rerouteDelay = 15; announced = []; lastSpokenAt = nil
        isFreeDriving = false
        objective = .fastest
        maxExtraDurationPercent = 30
        onRouteChanged?()
    }

    func consume(_ fix: LocationFix?) {
        guard isNavigating, !isPaused, let route = selectedRoute else { return }
        guard let fix, fix.hasUsablePosition(at: now()) else {
            audio.stop(); message = String(localized: "GPS unavailable. Guidance paused until position recovers."); return
        }
        guard let rawUpdate = tracker?.update(fix, at: now()) else { return }
        let update = trafficAdjusted(rawUpdate)
        progress = update
        if update.arrived {
            cancelRequest()
            isNavigating = false; isPaused = false
            message = String(localized: "You have arrived")
            if !muted { audio.speak(route.maneuvers.last!.spokenInstruction, language: route.language) }
            return
        }
        if update.offRoute {
            message = String(localized: "Off route. Recalculating when the routing service is available…")
            if !isLoading, lastReroute.map({ now().timeIntervalSince($0) >= rerouteDelay }) ?? true {
                lastReroute = now(); calculate(fix: fix, rerouting: true)
            }
            return
        }
        if rerouteInFlight, update.onRoute {
            // A confirmed return to the loaded route supersedes the pending detour.
            cancelRequest()
        }
        if !isLoading { message = nil }
        let maneuver = route.maneuvers[update.maneuverIndex]
        guard maneuver.type != "arrive" else { return }
        let key = "\(route.id)-\(maneuver.id)"
        let trigger = max(60, min(500, max(0, fix.speed) * 12))
        guard !muted, lastSpokenAt.map({ now().timeIntervalSince($0) >= 3 }) ?? true else { return }
        if update.maneuverDistance <= trigger, !announced.contains(key) {
            announced.insert(key); audio.speak(maneuver.spokenInstruction, language: route.language); lastSpokenAt = now()
            if maneuver.multiCue, update.maneuverIndex + 1 < route.maneuvers.count {
                announced.insert("\(route.id)-\(route.maneuvers[update.maneuverIndex + 1].id)")
            }
        } else if let alert = maneuver.spokenAlert, !alert.isEmpty,
                  update.maneuverDistance <= max(300, min(2000, max(0, fix.speed) * 30)),
                  !announced.contains(key + "-alert"), !announced.contains(key) {
            announced.insert(key + "-alert"); audio.speak(alert, language: route.language); lastSpokenAt = now()
        }
    }

    func loadDemo() throws {
        guard let url = Bundle.main.url(forResource: "route-response", withExtension: "json") else { throw RoutingError.invalidResponse }
        end()
        routes = try RoadScoutRoutingProvider.decode(Data(contentsOf: url)); selectedRoute = routes.first
        if let point = routes.first?.geometry.last { destination = Destination(name: String(localized: "Synthetic navigation demo"), point: point) }
        onRouteChanged?()
    }

    private func calculate(fix: LocationFix, rerouting: Bool) {
        let rawHeading = fix.speed > 2 && fix.course.isFinite && (0..<360).contains(fix.course) ? fix.course : nil
        let heading = rawHeading.map { value in headingSmoother?.update(heading: value, timestamp: now()) ?? value }
        calculate(origin: GeoPoint(latitude: fix.latitude, longitude: fix.longitude), heading: heading, rerouting: rerouting)
    }

    private func calculate(origin: GeoPoint, heading: Double?, rerouting: Bool) {
        guard let destination else { return }
        cancelRequest(); isLoading = true; message = rerouting ? message : nil
        rerouteInFlight = rerouting
        let current = token
        let request = RouteRequest(origin: origin, destination: destination.point,
                                   preferences: preferences, originHeading: heading,
                                   objective: objective, maxExtraDurationPercent: maxExtraDurationPercent)
        task = Task { [weak self, provider, endpoint] in
            do {
                let service = try provider(endpoint)
                let result = try await service.routes(for: request)
                try Task.checkCancellation()
                guard let self, token == current else { return }
                guard !result.isEmpty else { throw RoutingError.noRoute }
                routes = result; selectedRoute = result[0]; progress = nil; tracker = NavigationTracker(route: result[0])
                trafficETA = nil
                rerouteInFlight = false
                isLoading = false; message = nil; rerouteDelay = 15; announced = []
                onRouteChanged?()
            } catch {
                guard let self, token == current else { return }
                isLoading = false
                rerouteInFlight = false
                if error is CancellationError { return }
                message = error.localizedDescription
                if rerouting { rerouteDelay = min(120, rerouteDelay * 2) }
            }
        }
    }

    private func cancelRequest() { token = UUID(); task?.cancel(); task = nil; isLoading = false; rerouteInFlight = false }

    // Heading smoother integration helpers.
    func setHeadingSmoother(_ smoother: HeadingSmoother?) { headingSmoother = smoother }
    func useHeadingSmoother(_ smoother: HeadingSmoother?) { headingSmoother = smoother }
    func configureHeadingSmoother(_ smoother: HeadingSmoother?) { headingSmoother = smoother }

    func smoothedHeading(_ heading: Double, timestamp: Date) -> Double {
        headingSmoother?.update(heading: heading, timestamp: timestamp) ?? heading
    }
    func smoothedHeading(_ heading: Double, at timestamp: Date) -> Double {
        smoothedHeading(heading, timestamp: timestamp)
    }
    func smoothHeading(_ heading: Double, timestamp: Date) -> Double { smoothedHeading(heading, timestamp: timestamp) }
    func smoothHeading(_ heading: Double, at timestamp: Date) -> Double { smoothedHeading(heading, timestamp: timestamp) }
    func smooth(_ heading: Double, timestamp: Date) -> Double { smoothedHeading(heading, timestamp: timestamp) }
    func smooth(_ heading: Double, at timestamp: Date) -> Double { smoothedHeading(heading, timestamp: timestamp) }
    func headingSmoothed(_ heading: Double, timestamp: Date) -> Double { smoothedHeading(heading, timestamp: timestamp) }
    func headingSmoothed(_ heading: Double, at timestamp: Date) -> Double { smoothedHeading(heading, timestamp: timestamp) }

    func smoothedHeading(for fix: LocationFix, at date: Date? = nil) -> Double {
        let timestamp = date ?? fix.timestamp
        let raw = (fix.speed > 2 && fix.course.isFinite && (0..<360).contains(fix.course)) ? fix.course : 0
        return headingSmoother?.update(heading: raw, timestamp: timestamp) ?? raw
    }
    func smoothedHeading(for fix: LocationFix, timestamp: Date? = nil) -> Double {
        smoothedHeading(for: fix, at: timestamp)
    }
    func smoothedHeading(fix: LocationFix, date: Date? = nil) -> Double {
        smoothedHeading(for: fix, at: date)
    }
    func smoothHeading(for fix: LocationFix, at date: Date? = nil) -> Double {
        smoothedHeading(for: fix, at: date)
    }
    func locationArrowHeading(for fix: LocationFix, at date: Date? = nil) -> Double {
        smoothedHeading(for: fix, at: date)
    }
    func arrowHeading(for fix: LocationFix, at date: Date? = nil) -> Double {
        smoothedHeading(for: fix, at: date)
    }

    func smoothedHeading() -> Double? { headingSmoother?.smoothedHeading }
    func currentSmoothedHeading() -> Double? { headingSmoother?.smoothedHeading }

    func openPreview(_ destination: Destination, fix: LocationFix?, endpoint: String, preferences: RoutePreferences) { preview(destination, fix: fix, endpoint: endpoint, preferences: preferences) }
    func showRoutePreview(_ destination: Destination, fix: LocationFix?, endpoint: String, preferences: RoutePreferences) { preview(destination, fix: fix, endpoint: endpoint, preferences: preferences) }
    func presentRoutePreview(_ destination: Destination, fix: LocationFix?, endpoint: String, preferences: RoutePreferences) { preview(destination, fix: fix, endpoint: endpoint, preferences: preferences) }
    func previewInSheet(_ destination: Destination, fix: LocationFix?, endpoint: String, preferences: RoutePreferences) { preview(destination, fix: fix, endpoint: endpoint, preferences: preferences) }
    func previewInDrawer(_ destination: Destination, fix: LocationFix?, endpoint: String, preferences: RoutePreferences) { preview(destination, fix: fix, endpoint: endpoint, preferences: preferences) }
    func routePreview(_ destination: Destination, fix: LocationFix?, endpoint: String, preferences: RoutePreferences) { preview(destination, fix: fix, endpoint: endpoint, preferences: preferences) }
    func selectDestinationAndPreview(_ destination: Destination, fix: LocationFix?, endpoint: String, preferences: RoutePreferences) { preview(destination, fix: fix, endpoint: endpoint, preferences: preferences) }
    func chooseDestination(_ destination: Destination, fix: LocationFix?, endpoint: String, preferences: RoutePreferences) { preview(destination, fix: fix, endpoint: endpoint, preferences: preferences) }
    func destinationSelected(_ destination: Destination, fix: LocationFix?, endpoint: String, preferences: RoutePreferences) { preview(destination, fix: fix, endpoint: endpoint, preferences: preferences) }

    func startFreeDriveButton() { startFreeDrive() }
    func onDriveButton() { startFreeDrive() }
    func driveButtonTapped() { startFreeDrive() }
    func startFreeDrivingButton() { startFreeDrive() }

    deinit { task?.cancel() }
}
