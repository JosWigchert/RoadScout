import Foundation

struct CameraRoadProjection {
    var along: Double
    var lateral: Double
    var bearing: Double
    var length: Double
}

struct CameraAlertEvaluator {
    private(set) var alert: CameraWarning?
    private var announced: Set<String> = []
    private var enteredZones: Set<String> = []

    mutating func reset() { alert = nil; announced = []; enteredZones = [] }

    static func angle(_ a: Double, _ b: Double) -> Double {
        abs((a - b + 540).truncatingRemainder(dividingBy: 360) - 180)
    }
    static func routeBearing(at meters: Double, on route: DrivingRoute) -> Double? {
        guard meters.isFinite, meters >= 0, let end = route.cumulativeMeters.last, meters <= end else { return nil }
        for index in 0..<(route.geometry.count - 1) {
            guard route.cumulativeMeters[index + 1] - route.cumulativeMeters[index] > 0.5 else { continue }
            if meters <= route.cumulativeMeters[index + 1] {
                return NavigationTracker.bearing(route.geometry[index], route.geometry[index + 1])
            }
        }
        return nil
    }
    static func project(_ point: GeoPoint, on geometry: [GeoPoint]) -> CameraRoadProjection? {
        guard geometry.count >= 2, geometry.allSatisfy(\.isValid) else { return nil }
        var projections: [CameraRoadProjection] = [], length = 0.0
        for (a, b) in zip(geometry, geometry.dropFirst()) {
            let segment = a.distance(to: b)
            guard segment > 0.5 else { continue }
            let p = NavigationTracker.project(point, a, b)
            projections.append(.init(along: length + p.fraction * segment, lateral: p.distance,
                                     bearing: NavigationTracker.bearing(a, b), length: 0))
            length += segment
        }
        guard var best = projections.min(by: { $0.lateral < $1.lateral }) else { return nil }
        // Junctions, loops and overlapping carriageways can have multiple equally plausible positions.
        guard !projections.contains(where: { $0.lateral <= best.lateral + 3 && abs($0.along - best.along) > 25 }) else { return nil }
        best.length = length
        return best
    }

    mutating func consume(cameras: [CameraRecord], zones: [AverageSpeedZone], fix: LocationFix?,
                          heading: Double, route: DrivingRoute?, progress: NavigationProgress?,
                          routeEvidenceValid: Bool = true, isDriving: Bool,
                          settings: CameraWarningSettings, now: Date = Date()) -> CameraWarning? {
        alert = nil
        guard settings.enabled, isDriving, let fix, fix.hasUsablePosition(at: now),
              fix.horizontalAccuracy <= 15, fix.speed.isFinite, fix.speed >= 2,
              fix.course.isFinite, (0..<360).contains(fix.course), heading.isFinite,
              (0..<360).contains(heading), Self.angle(heading, fix.course) <= 45 else { return nil }
        let position = GeoPoint(latitude: fix.latitude, longitude: fix.longitude)
        let range = settings.warningDistanceMeters.isFinite ? min(2000, max(50, settings.warningDistanceMeters)) : 500
        var candidates: [CameraWarning] = []
        var retained: Set<String> = []
        for camera in cameras where camera.kind != "average_speed" {
            let direct = position.distance(to: camera.coordinate)
            if direct > range + 250 { continue }
            retained.insert(camera.id)
            var distance = direct, confident = false
            if let route {
                if routeEvidenceValid, let progress, !progress.offRoute, !progress.arrived,
                   let along = camera.routeDistanceMeters, along.isFinite {
                    distance = along - progress.traveledMeters
                    guard distance >= 0, distance <= range else { continue }
                    // Future enforcement direction belongs to the camera's route segment, not the car's current segment.
                    if let currentBearing = Self.routeBearing(at: progress.traveledMeters, on: route),
                       let cameraBearing = Self.routeBearing(at: along, on: route) {
                        guard Self.angle(currentBearing, fix.course) <= 40 else { continue }
                        confident = camera.routeMatch == "confirmed" && camera.directionDegrees.map {
                            $0.isFinite && (0..<360).contains($0) && Self.angle($0, cameraBearing) <= 40
                        } == true
                    }
                } else {
                    guard direct <= range, Self.angle(NavigationTracker.bearing(position, camera.coordinate), fix.course) < 75 else { continue }
                }
            } else {
                guard direct <= range, Self.angle(NavigationTracker.bearing(position, camera.coordinate), fix.course) < 75 else { continue }
                if let road = camera.roadGeometry,
                   let car = Self.project(position, on: road), let target = Self.project(camera.coordinate, on: road) {
                    let forward = Self.angle(car.bearing, fix.course) <= 35
                    let reverse = Self.angle(car.bearing + 180, fix.course) <= 35
                    distance = (target.along - car.along) * (forward ? 1 : -1)
                    guard car.lateral <= 8, target.lateral <= 15, forward || reverse, distance >= 0, distance <= range else { continue }
                    // Ordered road geometry alone does not establish enforcement travel direction.
                    confident = camera.association != "unknown" && camera.directionDegrees.map {
                        $0.isFinite && (0..<360).contains($0) && Self.angle($0, fix.course) <= 35
                    } == true
                }
            }
            let title = confident ? "Mapped camera ahead" : "Mapped camera nearby"
            candidates.append(.init(id: camera.id, title: title, distanceMeters: distance,
                                    maxSpeedKph: camera.maxSpeedKph.flatMap { $0 > 0 ? $0 : nil },
                                    isAverageZone: false, isInsideZone: false, confident: confident,
                                    announcement: confident ? "Mapped camera ahead in \(Int(distance.rounded())) meters." : ""))
        }
        for zone in zones where zone.geometryVerified && zone.geometry.count >= 2 {
            // A temporary heading mismatch must not create a fresh pass through the same zone.
            let nearZone = zip(zone.geometry, zone.geometry.dropFirst()).contains {
                NavigationTracker.project(position, $0, $1).distance <= range + 250
            }
            if nearZone {
                for suffix in ["entry", "inside", "exit"] { retained.insert(zone.id + ":" + suffix) }
            }
            guard let car = Self.project(position, on: zone.geometry), car.lateral <= 8,
                  Self.angle(car.bearing, fix.course) <= 35 else { continue }
            let entry = zone.geometry[0], exit = zone.geometry[zone.geometry.count - 1]
            var distance = position.distance(to: entry), inside = car.along > 5 && car.along < car.length - 5
            var phase = inside ? "inside" : "entry"
            var confident = route == nil
            if route != nil {
                guard routeEvidenceValid, let progress, !progress.offRoute, !progress.arrived,
                      zone.routeMatch == "confirmed", let start = zone.routeStartMeters, let end = zone.routeEndMeters,
                      start.isFinite, end.isFinite, end > start else { continue }
                inside = progress.traveledMeters >= start && progress.traveledMeters < end
                distance = start - progress.traveledMeters
                phase = inside ? "inside" : "entry"; confident = true
                if progress.traveledMeters >= end, enteredZones.contains(zone.id), position.distance(to: exit) < 50 { phase = "exit" }
            } else if enteredZones.contains(zone.id), car.along >= car.length - 5, position.distance(to: exit) < 50 {
                phase = "exit"
            }
            if inside { enteredZones.insert(zone.id) }
            if phase == "entry" {
                guard distance >= 0, distance <= range,
                      zone.directionDegrees.map({
                          $0.isFinite && (0..<360).contains($0)
                              && Self.angle($0, NavigationTracker.bearing(zone.geometry[0], zone.geometry[1])) <= 40
                      }) == true,
                      Self.angle(NavigationTracker.bearing(position, entry), fix.course) < 75 else { continue }
            }
            for suffix in ["entry", "inside", "exit"] { retained.insert(zone.id + ":" + suffix) }
            let title = phase == "exit" ? "Mapped average-speed zone ends" : inside ? "Inside mapped average-speed zone" : "Mapped average-speed zone ahead"
            candidates.append(.init(id: zone.id + ":" + phase, title: title,
                                    distanceMeters: phase == "entry" ? distance : nil, maxSpeedKph: zone.maxSpeedKph,
                                    isAverageZone: true, isInsideZone: inside, confident: confident,
                                    announcement: phase == "entry" ? "Mapped average-speed zone ahead." : ""))
        }
        announced.formIntersection(retained)
        enteredZones = enteredZones.filter { id in retained.contains(id + ":inside") }
        alert = candidates.sorted {
            if $0.confident != $1.confident { return $0.confident }
            return ($0.distanceMeters ?? 0) < ($1.distanceMeters ?? 0)
        }.first
        guard let alert, alert.confident, !alert.announcement.isEmpty else { return nil }
        let first = announced.insert(alert.id).inserted
        return first && settings.audioEnabled ? alert : nil
    }
}
