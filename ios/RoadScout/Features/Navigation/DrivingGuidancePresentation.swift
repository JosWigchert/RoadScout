import Foundation

struct DrivingGuidancePresentation {
    enum Mode: Equatable { case freeDrive, loading, unavailable, ready, following, navigating, paused, arrived }
    let mode: Mode
    let title: String
    let instruction: String?
    let symbol: String
    let maneuverDistance: Double?
    let remainingMeters: Double?
    let remainingSeconds: Double?
    let message: String?

    var canStart: Bool { mode == .ready || mode == .paused }
    var canRetry: Bool { mode == .unavailable }
    var showsTravelMetrics: Bool { remainingMeters != nil && remainingSeconds != nil }

    init(route: DrivingRoute?, progress: NavigationProgress?, isNavigating: Bool, isPaused: Bool,
         isLoading: Bool, hasDestination: Bool, destinationName: String?, message: String?) {
        if route == nil {
            mode = !hasDestination ? .freeDrive : (isLoading ? .loading : .unavailable)
        } else if progress?.arrived == true {
            mode = .arrived
        } else if isPaused {
            mode = .paused
        } else if isNavigating, let progress, route!.maneuvers.indices.contains(progress.maneuverIndex) {
            mode = .navigating
        } else if isNavigating {
            mode = .following
        } else {
            mode = .ready
        }
        if mode == .navigating, let route, let progress {
            let maneuver = route.maneuvers[progress.maneuverIndex]
            title = String(localized: "Next maneuver")
            instruction = maneuver.instruction
            symbol = Self.symbol(type: maneuver.type, modifier: maneuver.modifier)
            maneuverDistance = max(0, progress.maneuverDistance)
        } else {
            maneuverDistance = nil
            switch mode {
            case .freeDrive:
                title = String(localized: "Free drive"); instruction = nil; symbol = "steeringwheel"
            case .loading:
                title = String(localized: "Preparing your route"); instruction = destinationName; symbol = "car.fill"
            case .unavailable:
                title = String(localized: "Route unavailable"); instruction = destinationName; symbol = "wifi.exclamationmark"
            case .paused:
                title = String(localized: "Navigation paused"); instruction = destinationName; symbol = "pause.fill"
            case .arrived:
                title = String(localized: "You have arrived"); instruction = destinationName; symbol = "flag.checkered"
            case .following:
                title = String(localized: "Following route"); instruction = destinationName; symbol = "arrow.up"
            default:
                title = String(localized: "Route ready"); instruction = destinationName; symbol = "arrow.up"
            }
        }
        if mode == .arrived || route == nil {
            remainingMeters = nil; remainingSeconds = nil
        } else {
            remainingMeters = max(0, progress?.remainingMeters ?? route!.distanceMeters)
            remainingSeconds = max(0, progress?.remainingSeconds ?? route!.durationSeconds)
        }
        self.message = isLoading && route != nil ? String(localized: "Recalculating route…") : (mode == .freeDrive || mode == .arrived ? nil : message)
    }

    func arrival(at now: Date) -> Date? {
        guard mode != .paused, let remainingSeconds else { return nil }
        return now.addingTimeInterval(remainingSeconds)
    }

    private static func symbol(type: String, modifier: String) -> String {
        if modifier == "uturn" { return "arrow.uturn.down" }
        switch type {
        case "roundabout_enter", "roundabout_exit": return "arrow.triangle.turn.up.right.diamond"
        case "merge": return "arrow.merge"
        case "fork", "on_ramp", "off_ramp": return modifier.contains("left") ? "arrow.up.left" : "arrow.up.right"
        case "arrive": return "flag.checkered"
        default:
            if modifier.contains("left") { return "arrow.turn.up.left" }
            if modifier.contains("right") { return "arrow.turn.up.right" }
            return "arrow.up"
        }
    }
}
