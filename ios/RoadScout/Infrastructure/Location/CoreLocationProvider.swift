import CoreLocation

@MainActor
final class CoreLocationProvider: NSObject, LocationProviding, @preconcurrency CLLocationManagerDelegate {
    var onEvent: ((LocationEvent) -> Void)?
    private let manager: CLLocationManager
    private var active = false
    private var serviceCheck: Task<Void, Never>?

    override init() {
        manager = CLLocationManager()
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .automotiveNavigation
        manager.headingFilter = 3
    }

    func start() {
        stop()
        active = true
        serviceCheck = Task { [weak self] in
            let enabled = await Task.detached { CLLocationManager.locationServicesEnabled() }.value
            guard !Task.isCancelled, let self, active else { return }
            guard enabled else {
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
    }

    private func updateAuthorization() {
        guard active else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            onEvent?(.access(.notDetermined))
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            onEvent?(.access(.authorized))
            manager.startUpdatingLocation()
            if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
        case .denied: onEvent?(.access(.denied))
        case .restricted: onEvent?(.access(.restricted))
        @unknown default: onEvent?(.access(.restricted))
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
                                course: location.course, timestamp: location.timestamp)))
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard active, newHeading.headingAccuracy >= 0,
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
}
