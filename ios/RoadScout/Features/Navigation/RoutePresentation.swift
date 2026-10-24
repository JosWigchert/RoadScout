import Foundation

enum RoutePresentation {
    static func title(for route: DrivingRoute, in routes: [DrivingRoute]) -> String {
        if route.id == routes.first?.id, let objective = route.objective, objective.isExperimental,
           route.experiment?.status == "improved", route.experiment?.effectiveObjective == objective.rawValue { return objective.fallbackTitle }
        let fastest = routes.min { $0.durationSeconds < $1.durationSeconds }
        if route.id == fastest?.id { return String(localized: "Fastest") }
        let index = routes.firstIndex(where: { $0.id == route.id }) ?? 0
        if let via = corridorLabel(for: route) {
            let matches = routes.filter { corridorLabel(for: $0) == via && $0.id != fastest?.id }
            return matches.count > 1 ? "\(via) · \(String(localized: "Route \(index + 1)"))" : via
        }
        return index == 0 ? String(localized: "Recommended") : String(localized: "Alternative \(index)")
    }

    static func corridorLabel(for route: DrivingRoute) -> String? {
        var distances: [String: Double] = [:]
        var references = Set<String>()
        for maneuver in route.maneuvers {
            let names = maneuver.streetNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let roadReference = names.first { $0.range(of: #"^[A-Za-z]{1,3}\s*\d+[A-Za-z]?$"#, options: .regularExpression) != nil }
            guard let raw = roadReference ?? names.first else { continue }
            let name = roadReference == nil ? raw : raw.uppercased().replacingOccurrences(of: " ", with: "")
            if roadReference != nil { references.insert(name) }
            let start = min(max(0, maneuver.beginIndex), route.cumulativeMeters.count - 1)
            let end = min(max(start, maneuver.endIndex), route.cumulativeMeters.count - 1)
            let supplied = maneuver.distanceMeters.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            distances[name, default: 0] += max(1, supplied ?? (route.cumulativeMeters[end] - route.cumulativeMeters[start]))
        }
        let candidates = distances.filter { references.isEmpty || references.contains($0.key) }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        guard let first = candidates.first else { return nil }
        let names = candidates.filter { $0.value >= first.value * 0.25 }.prefix(2).map(\.key)
        return String(localized: "Via \(names.joined(separator: " · "))")
    }
}
