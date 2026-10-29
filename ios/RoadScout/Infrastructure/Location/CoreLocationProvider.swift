import CoreLocation

@MainActor protocol DrivingLocationManaging: AnyObject {
    var delegate: (any CLLocationManagerDelegate)? { get set }
    var authorizationStatus: CLAuthorizationStatus { get }
    var desiredAccuracy: CLLocationAccuracy { get set }
    var distanceFilter: CLLocationDistance { get set }
    var activityType: CLActivityType { get set }
    var headingFilter: CLLocationDegrees { get set }
    var allowsBackgroundLocationUpdates: Bool { get set }
    var pausesLocationUpdatesAutomatically: Bool { get set }
    var showsBackgroundLocationIndicator: Bool { get set }
    func requestWhenInUseAuthorization()
    func startUpdatingLocation()
    func stopUpdatingLocation()
    func startUpdatingHeading()
    func stopUpdatingHeading()
}

extension CLLocationManager: DrivingLocationManaging {}

@MainActor
final class CoreLocationProvider: NSObject, LocationProviding, @preconcurrency CLLocationManagerDelegate {
    var onEvent: ((LocationEvent) -> Void)?
    private let manager: any DrivingLocationManaging
    private let supportsBackgroundLocation: Bool
    private let servicesEnabled: @Sendable () -> Bool
    private let headingAvailable: () -> Bool
    private var active = false
    private var backgrounded = false
    private var locationRunning = false
    private var headingRunning = false
    private var serviceCheck: Task<Void, Never>?

    init(manager: any DrivingLocationManaging = CLLocationManager(),
         supportsBackgroundLocation: Bool = (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?.contains("location") == true,
         servicesEnabled: @escaping @Sendable () -> Bool = { CLLocationManager.locationServicesEnabled() },
         headingAvailable: @escaping () -> Bool = { CLLocationManager.headingAvailable() }) {
        self.manager = manager
        self.supportsBackgroundLocation = supportsBackgroundLocation
        self.servicesEnabled = servicesEnabled
        self.headingAvailable = headingAvailable
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .automotiveNavigation
        manager.headingFilter = 3
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = false
    }

    func start() {
        stop()
        active = true
        let servicesEnabled = servicesEnabled
        serviceCheck = Task { [weak self] in
            let enabled = await Task.detached { servicesEnabled() }.value
            guard !Task.isCancelled, let self, active else { return }
            guard enabled else {
                stop()
                onEvent?(.access(.servicesDisabled))
                return
            }
            updateAuthorization()
        }
    }

    func stop() {
        active = false
        serviceCheck?.cancel()
        serviceCheck = nil
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
        locationRunning = false; headingRunning = false; backgrounded = false
    }

    func setBackgrounded(_ backgrounded: Bool) {
        self.backgrounded = backgrounded
        guard active else { return }
        updateAuthorization()
    }

    private func updateAuthorization() {
        guard active else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            onEvent?(.access(.notDetermined))
            if !backgrounded { manager.requestWhenInUseAuthorization() }
        case .authorizedAlways, .authorizedWhenInUse:
            onEvent?(.access(.authorized))
            // A foreground-started When In Use session can continue with the visible
            // background location indicator. Never escalate to Always authorization.
            manager.allowsBackgroundLocationUpdates = supportsBackgroundLocation
            manager.showsBackgroundLocationIndicator = supportsBackgroundLocation
            if !locationRunning { manager.startUpdatingLocation(); locationRunning = true }
            if backgrounded {
                if headingRunning { manager.stopUpdatingHeading(); headingRunning = false }
            } else if !headingRunning, headingAvailable() {
                manager.startUpdatingHeading(); headingRunning = true
            }
        case .denied: stop(); onEvent?(.access(.denied))
        case .restricted: stop(); onEvent?(.access(.restricted))
        @unknown default: stop(); onEvent?(.access(.restricted))
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        updateAuthorization()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard active, let location = locations.last else { return }
        onEvent?(.fix(LocationFix(latitude: location.coordinate.latitude,
                                longitude: location.coordinate.longitude,
                                speed: location.speed, speedAccuracy: location.speedAccuracy,
                                horizontalAccuracy: location.horizontalAccuracy,
                                course: location.course, timestamp: location.timestamp,
                                courseAccuracy: location.courseAccuracy)))
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard active, !backgrounded, newHeading.headingAccuracy >= 0,
              Date().timeIntervalSince(newHeading.timestamp) <= 5 else { return }
        let heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        onEvent?(.heading(heading))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard active else { return }
        if (error as? CLError)?.code == .denied {
            onEvent?(.access(.denied))
        } else {
            onEvent?(.failure)
        }
    }

    isolated deinit { stop() }
}
