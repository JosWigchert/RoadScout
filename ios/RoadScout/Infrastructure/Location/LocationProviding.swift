import CoreLocation

enum LocationAccess: Equatable {
    case notDetermined, authorized, denied, restricted, servicesDisabled
}

struct LocationFix: Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    var speed: Double
    var speedAccuracy: Double
    var horizontalAccuracy: Double
    var course: Double
    var timestamp: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    func hasUsablePosition(at now: Date) -> Bool {
        latitude.isFinite && longitude.isFinite
            && (-90...90).contains(latitude) && (-180...180).contains(longitude)
            && horizontalAccuracy.isFinite && (0...50).contains(horizontalAccuracy)
            && (-1...5).contains(now.timeIntervalSince(timestamp))
    }
}

enum LocationEvent {
    case access(LocationAccess)
    case fix(LocationFix)
    case heading(Double)
    case failure
    case finished
}

@MainActor
protocol LocationProviding: AnyObject {
    var onEvent: ((LocationEvent) -> Void)? { get set }
    func start()
    func stop()
}
