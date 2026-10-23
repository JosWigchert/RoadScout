import Foundation

enum PlaceSortOrder: String, CaseIterable, Identifiable {
    case nearest, relevance
    var id: Self { self }
    var title: String {
        self == .nearest ? String(localized: "Nearest first") : String(localized: "Best match")
    }
}

enum PlaceProximity {
    /// Never reuse a persisted distance: it belongs to a previous origin.
    static func updated(_ places: [Destination], origin: GeoPoint?, order: PlaceSortOrder = .nearest) -> [Destination] {
        let currentOrigin = origin.flatMap { $0.isValid ? $0 : nil }
        let measured = places.filter { $0.point.isValid }.map { place in
            place.withDistance(currentOrigin.map { $0.distance(to: place.point) })
        }
        guard currentOrigin != nil, order == .nearest else { return measured }
        return measured.enumerated().sorted { lhs, rhs in
            let a = lhs.element.distance ?? .infinity
            let b = rhs.element.distance ?? .infinity
            return a == b ? lhs.offset < rhs.offset : a < b
        }.map(\.element)
    }
}
