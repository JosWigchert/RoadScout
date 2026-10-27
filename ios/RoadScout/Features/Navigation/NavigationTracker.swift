import Foundation

struct NavigationProgress: Equatable {
    let traveledMeters: Double
    let remainingMeters: Double
    let remainingSeconds: Double
    let maneuverIndex: Int
    let maneuverDistance: Double
    let offRoute: Bool
    let arrived: Bool
    var onRoute: Bool = true
}

protocol NavigationTracking {
    mutating func update(_ fix: LocationFix, at now: Date) -> NavigationProgress?
}

struct NavigationTracker: NavigationTracking {
    let route: DrivingRoute
    private(set) var progressMeters: Double = 0
    private var lastTimestamp: Date?
    private var offRouteSince: Date?
    private var arrivalCount = 0
    private var matched = false

    mutating func update(_ fix: LocationFix, at now: Date) -> NavigationProgress? {
        guard fix.hasUsablePosition(at: now), lastTimestamp.map({ fix.timestamp > $0 }) ?? true else { return nil }
        let dt = lastTimestamp.map { max(0, fix.timestamp.timeIntervalSince($0)) } ?? 0
        lastTimestamp = fix.timestamp
        if dt > 5 { offRouteSince = nil; arrivalCount = 0 }
        let position = GeoPoint(latitude: fix.latitude, longitude: fix.longitude)
        var best: (score: Double, distance: Double, along: Double, wrongDirection: Bool)?
        let window = max(250, min(2000, dt * max(40, fix.speed.isFinite ? max(0, fix.speed) : 0) + 100))
        for i in 0..<(route.geometry.count - 1) {
            if matched, route.cumulativeMeters[i + 1] < progressMeters - 60 || route.cumulativeMeters[i] > progressMeters + window { continue }
            let a = route.geometry[i], b = route.geometry[i + 1]
            if route.cumulativeMeters[i + 1] - route.cumulativeMeters[i] < 0.1 { continue }
            let projection = Self.project(position, a, b)
            let along = route.cumulativeMeters[i] + projection.fraction * (route.cumulativeMeters[i + 1] - route.cumulativeMeters[i])
            var score = projection.distance
            var wrongDirection = false
            if fix.speed > 2, fix.course.isFinite, (0..<360).contains(fix.course) {
                let bearing = Self.bearing(a, b)
                let angle = abs((bearing - fix.course + 540).truncatingRemainder(dividingBy: 360) - 180)
                score += angle / 3
                wrongDirection = angle > 110 && fix.speed >= 4 && fix.speedAccuracy.isFinite && (0...3).contains(fix.speedAccuracy)
            }
            if matched { score += abs(along - progressMeters) * 0.015 }
            if best == nil || score < best!.score { best = (score, projection.distance, along, wrongDirection) }
        }
        guard let best else { return nil }
        let outside = best.distance > max(35, fix.horizontalAccuracy * 1.5) || best.wrongDirection
        if outside {
            if offRouteSince == nil { offRouteSince = fix.timestamp }
        } else {
            offRouteSince = nil
            progressMeters = max(progressMeters, best.along)
            matched = true
        }
        let offRoute = offRouteSince.map { fix.timestamp.timeIntervalSince($0) >= 3 } ?? false
        let shapeRemaining = max(0, route.cumulativeMeters.last! - progressMeters)
        let nearEnd = !outside && shapeRemaining < 25 && position.distance(to: route.geometry.last!) < 30
        arrivalCount = nearEnd ? arrivalCount + 1 : 0
        let next = route.maneuvers.indices.first { route.cumulativeMeters[route.maneuvers[$0].beginIndex] > progressMeters + 8 }
            ?? route.maneuvers.indices.last!
        let ratio = shapeRemaining / route.cumulativeMeters.last!
        return NavigationProgress(traveledMeters: progressMeters, remainingMeters: route.distanceMeters * ratio,
                                  remainingSeconds: max(0, route.durationSeconds - route.elapsedSeconds(at: progressMeters)),
                                  maneuverIndex: next, maneuverDistance: max(0, route.cumulativeMeters[route.maneuvers[next].beginIndex] - progressMeters),
                                   offRoute: offRoute, arrived: arrivalCount >= 2, onRoute: !outside)
    }

    static func project(_ p: GeoPoint, _ a: GeoPoint, _ b: GeoPoint) -> (fraction: Double, distance: Double) {
        let r = Double.pi / 180, scale = 6_371_000.0
        func longitudeDelta(_ x: Double) -> Double { (x + 540).truncatingRemainder(dividingBy: 360) - 180 }
        let x = longitudeDelta(b.longitude - a.longitude) * r * cos(a.latitude * r) * scale
        let y = (b.latitude - a.latitude) * r * scale
        let px = longitudeDelta(p.longitude - a.longitude) * r * cos(a.latitude * r) * scale
        let py = (p.latitude - a.latitude) * r * scale
        let length = x * x + y * y
        let t = length > 0 ? min(1, max(0, (px * x + py * y) / length)) : 0
        return (t, hypot(px - t * x, py - t * y))
    }

    static func bearing(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let r = Double.pi / 180, d = (b.longitude - a.longitude) * r
        let y = sin(d) * cos(b.latitude * r)
        let x = cos(a.latitude * r) * sin(b.latitude * r) - sin(a.latitude * r) * cos(b.latitude * r) * cos(d)
        return (atan2(y, x) / r + 360).truncatingRemainder(dividingBy: 360)
    }
}
