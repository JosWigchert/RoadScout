import CoreLocation
import Observation

/// One foreground fix for place search, independent of a driving/GPS-speed session.
@MainActor @Observable final class PlanningLocationModel {
    private(set) var fix: LocationFix?
    private(set) var isRequesting = false
    private(set) var message: String?
    @ObservationIgnored private let provider: any LocationProviding
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var timeout: Task<Void, Never>?

    init(provider: any LocationProviding = PlanningLocationProvider(), now: @escaping () -> Date = Date.init) {
        self.provider = provider
        self.now = now
    }

    var currentPoint: GeoPoint? {
        guard let fix, Self.isUsable(fix, at: now()) else { return nil }
        return GeoPoint(latitude: fix.latitude, longitude: fix.longitude)
    }

    var routingFix: LocationFix? {
        guard let fix, fix.hasUsablePosition(at: now()) else { return nil }
        return fix
    }

    func request(refresh: Bool = false) {
        guard !isRequesting, refresh || currentPoint == nil else { return }
        message = nil
        isRequesting = true
        provider.onEvent = { [weak self] event in self?.receive(event) }
        provider.start()
        guard isRequesting else { return }
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            self?.fail(String(localized: "Location unavailable. Search still works without distances."))
        }
    }

    func stop(clearFix: Bool = false) {
        provider.onEvent = nil
        provider.stop()
        timeout?.cancel()
        timeout = nil
        isRequesting = false
        if clearFix { fix = nil }
    }

    private func receive(_ event: LocationEvent) {
        guard isRequesting else { return }
        switch event {
        case .fix(let fix):
            guard Self.isUsable(fix, at: now()) else {
                fail(String(localized: "Location unavailable. Search still works without distances."))
                return
            }
            self.fix = fix
            stop()
        case .access(.denied), .access(.restricted), .access(.servicesDisabled):
            fail(String(localized: "Location access is off. Search still works without distances."))
        case .failure, .finished:
            fail(String(localized: "Location unavailable. Search still works without distances."))
        default: break
        }
    }

    private func fail(_ message: String) {
        stop(clearFix: true)
        self.message = message
    }

    private static func isUsable(_ fix: LocationFix, at date: Date) -> Bool {
        fix.latitude.isFinite && fix.longitude.isFinite
            && (-90...90).contains(fix.latitude) && (-180...180).contains(fix.longitude)
            && fix.horizontalAccuracy.isFinite && (0...1_000).contains(fix.horizontalAccuracy)
            && (-1...300).contains(date.timeIntervalSince(fix.timestamp))
    }

    deinit { timeout?.cancel() }
}

@MainActor private final class PlanningLocationProvider: NSObject, LocationProviding, @preconcurrency CLLocationManagerDelegate {
    var onEvent: ((LocationEvent) -> Void)?
    private let manager = CLLocationManager()
    private var active = false
    private var requestedFix = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func start() {
        active = true
        requestedFix = false
        updateAuthorization()
    }

    func stop() {
        active = false
        requestedFix = false
        manager.stopUpdatingLocation()
    }

    private func updateAuthorization() {
        guard active else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            onEvent?(.access(.notDetermined))
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            guard !requestedFix else { return }
            requestedFix = true
            manager.requestLocation()
        case .denied: onEvent?(.access(.denied))
        case .restricted: onEvent?(.access(.restricted))
        @unknown default: onEvent?(.failure)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { updateAuthorization() }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard active, let location = locations.last else { return }
        onEvent?(.fix(LocationFix(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                                 speed: location.speed, speedAccuracy: location.speedAccuracy,
                                 horizontalAccuracy: location.horizontalAccuracy, course: location.course,
                                 timestamp: location.timestamp)))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard active else { return }
        onEvent?((error as? CLError)?.code == .denied ? .access(.denied) : .failure)
    }
}
