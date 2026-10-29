import Foundation

struct RouteProgressGeometry: Equatable {
    let completed: [GeoPoint]
    let remaining: [GeoPoint]

    /// Distances are route-shape arclength, as published by NavigationTracker,
    /// rather than the engine's potentially different summary distance.
    init(route: DrivingRoute, traveledMeters: Double?) {
        guard let traveledMeters, traveledMeters.isFinite, traveledMeters > 0 else {
            completed = []; remaining = route.geometry; return
        }
        guard let length = route.cumulativeMeters.last, traveledMeters < length else {
            completed = route.geometry; remaining = []; return
        }
        var lower = 0, upper = route.cumulativeMeters.count - 1
        while lower < upper {
            let middle = (lower + upper) / 2
            if route.cumulativeMeters[middle] < traveledMeters { lower = middle + 1 }
            else { upper = middle }
        }
        let index = lower
        if route.cumulativeMeters[index] == traveledMeters {
            completed = Array(route.geometry[...index])
            remaining = Array(route.geometry[index...])
            return
        }
        let a = route.geometry[index - 1], b = route.geometry[index]
        let distance = route.cumulativeMeters[index] - route.cumulativeMeters[index - 1]
        let fraction = distance > 0 ? (traveledMeters - route.cumulativeMeters[index - 1]) / distance : 0
        let longitudeDelta = (b.longitude - a.longitude + 540).truncatingRemainder(dividingBy: 360) - 180
        let longitude = a.longitude + longitudeDelta * fraction
        let cut = GeoPoint(latitude: a.latitude + (b.latitude - a.latitude) * fraction,
            longitude: (longitude + 540).truncatingRemainder(dividingBy: 360) - 180)
        completed = Array(route.geometry[..<index]) + [cut]
        remaining = [cut] + Array(route.geometry[index...])
    }
}
