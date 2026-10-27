import Foundation

struct DrivingMotionSample: Sendable {
    /// Seconds since boot, in the same domain as ProcessInfo.systemUptime.
    var timestamp: TimeInterval
    var accelerationNorth: Double?
    var accelerationEast: Double?
    var clockwiseYawRate: Double
    var rotationMagnitude: Double
    var gravityX: Double
    var gravityY: Double
    var gravityZ: Double
    var verticalAcceleration: Double
}

struct DrivingPose: Equatable {
    var point: GeoPoint
    var heading: Double
    var predictedSpeed: Double
    var motionAssisted: Bool
    var predictionLimited: Bool
}

/// A bounded, display-only complementary predictor. It never generates LocationFix values.
/// Core Location remains the authority for navigation, speed and enforcement warnings.
struct DrivingMotionEstimator {
    static let predictionHorizon: TimeInterval = 2
    private var point: GeoPoint?
    private var heading = 0.0
    private var speed = 0.0
    private var gpsSpeed = 0.0
    private var gpsAccuracy = 0.0
    private var lastFixTimestamp: Date?
    private var lastFixTime: TimeInterval?
    private var time: TimeInterval?
    private var motion: DrivingMotionSample?
    private var handlingUntil: TimeInterval = 0
    private var filteredAcceleration = 0.0
    private var correctionNorth = 0.0
    private var correctionEast = 0.0
    private var correctionHeading = 0.0
    private var pendingRelocation: (point: GeoPoint, time: TimeInterval)?
    private var hasTravelHeading = false

    mutating func reset() { self = Self() }

    @discardableResult
    mutating func ingest(_ fix: LocationFix, now: Date, uptime: TimeInterval) -> Bool {
        let age = now.timeIntervalSince(fix.timestamp)
        guard uptime.isFinite, fix.hasUsablePosition(at: now), age >= -0.1,
              age <= Self.predictionHorizon,
              lastFixTimestamp.map({ fix.timestamp > $0 }) ?? true else { return false }
        let measuredAt = uptime - max(0, age)
        guard lastFixTime.map({ measuredAt > $0 }) ?? true else { return false }
        advance(to: uptime)
        let validSpeed = fix.speed.isFinite && (0...100).contains(fix.speed)
            && fix.speedAccuracy.isFinite && (0...3).contains(fix.speedAccuracy)
        let measuredSpeed = validSpeed ? fix.speed : 0
        let hasCourse = fix.course.isFinite && (0..<360).contains(fix.course) && measuredSpeed > 2
            && (fix.courseAccuracy.map { $0.isFinite && (0...30).contains($0) } ?? true)
        let coordinate = GeoPoint(latitude: fix.latitude, longitude: fix.longitude)
        let measuredPoint = hasCourse ? Self.translate(coordinate,
            north: cos(fix.course * .pi / 180) * measuredSpeed * max(0, age),
            east: sin(fix.course * .pi / 180) * measuredSpeed * max(0, age)) : coordinate

        if let point {
            let residual = Self.offset(from: point, to: measuredPoint)
            let distance = hypot(residual.north, residual.east)
            let limit = max(60, speed * 2 + fix.horizontalAccuracy * 2)
            if distance > limit {
                // Require a second accurate, consistent fix before accepting a relocation.
                let confirmed = pendingRelocation.map {
                    uptime - $0.time <= 3 && $0.point.distance(to: measuredPoint) <= max(30, measuredSpeed * 2)
                } ?? false
                guard confirmed, fix.horizontalAccuracy <= 15 else {
                    pendingRelocation = fix.horizontalAccuracy <= 15 ? (measuredPoint, uptime) : nil
                    return false
                }
                self.point = measuredPoint
                correctionNorth = 0; correctionEast = 0
                correctionHeading = 0
                motion = nil; filteredAcceleration = 0
            } else {
                // A stopped car stays put inside its accuracy circle instead of wandering.
                let stationaryJitter = measuredSpeed < 0.5 && speed < 0.5
                    && distance < max(3, fix.horizontalAccuracy)
                if !stationaryJitter {
                    let gain = min(0.85, max(0.25, gpsAccuracy / max(1, gpsAccuracy + fix.horizontalAccuracy)))
                    self.point = Self.translate(point, north: residual.north * gain, east: residual.east * gain)
                    // Preserve the current displayed coordinate; retire the correction over subsequent frames.
                    correctionNorth -= residual.north * gain
                    correctionEast -= residual.east * gain
                }
            }
        } else {
            point = measuredPoint
        }
        pendingRelocation = nil
        lastFixTimestamp = fix.timestamp
        lastFixTime = measuredAt
        gpsAccuracy = max(1, fix.horizontalAccuracy)
        gpsSpeed = (hasCourse || (hasTravelHeading && measuredSpeed <= 2)) && measuredSpeed >= 0.5 ? measuredSpeed : 0
        // GPS speed is the drift anchor. Invalid speed disables extrapolation.
        speed = gpsSpeed
        if hasCourse {
            let difference = Self.delta(from: heading, to: fix.course)
            if hasTravelHeading, abs(difference) > 25 {
                handlingUntil = uptime + 2
                filteredAcceleration = 0
            }
            if hasTravelHeading {
                heading = Self.normalize(heading + difference * 0.8)
                correctionHeading -= difference * 0.8
            } else { heading = fix.course }
            hasTravelHeading = true
        }
        time = uptime
        return true
    }

    mutating func ingest(_ sample: DrivingMotionSample, uptime: TimeInterval) {
        guard sample.timestamp.isFinite, sample.clockwiseYawRate.isFinite,
              sample.rotationMagnitude.isFinite, sample.gravityX.isFinite,
              sample.gravityY.isFinite, sample.gravityZ.isFinite, sample.verticalAcceleration.isFinite,
              sample.accelerationNorth.map(\.isFinite) ?? true,
              sample.accelerationEast.map(\.isFinite) ?? true,
              sample.timestamp <= uptime + 0.02, uptime - sample.timestamp <= 0.2,
              motion.map({ sample.timestamp > $0.timestamp }) ?? true else { return }
        advance(to: min(uptime, sample.timestamp))
        var handled = sample.rotationMagnitude > 1.2 || abs(sample.verticalAcceleration) > 2.5
        if let previous = motion, sample.timestamp - previous.timestamp < 0.2 {
            let dot = previous.gravityX * sample.gravityX + previous.gravityY * sample.gravityY + previous.gravityZ * sample.gravityZ
            // A rapid change of phone tilt is handling, not a car turn.
            if dot < cos(12 * .pi / 180) { handled = true }
        }
        if handled { handlingUntil = uptime + 2; filteredAcceleration = 0 }
        motion = sample
    }

    mutating func pose(at uptime: TimeInterval) -> DrivingPose? {
        guard uptime.isFinite else { return nil }
        advance(to: uptime)
        guard let point, let lastFixTime else { return nil }
        let limited = uptime - lastFixTime >= Self.predictionHorizon
        return DrivingPose(point: Self.translate(point, north: correctionNorth, east: correctionEast),
                           heading: Self.normalize(heading + correctionHeading), predictedSpeed: speed,
                           motionAssisted: !limited && usableMotion(at: uptime) && speed > 0.5,
                           predictionLimited: limited)
    }

    private func usableMotion(at date: TimeInterval) -> Bool {
        guard let motion else { return false }
        return date >= motion.timestamp && date - motion.timestamp <= 0.15 && date >= handlingUntil
    }

    private mutating func advance(to target: TimeInterval) {
        guard target.isFinite else { return }
        guard let previous = time, let lastFixTime, var position = point else { return }
        guard target > previous else { return }
        let end = min(target, lastFixTime + Self.predictionHorizon)
        var cursor = previous
        while cursor < end {
            let dt = min(1.0 / 50, end - cursor)
            let assisted = usableMotion(at: cursor)
            var yawRate = 0.0
            if assisted, let motion, speed > 0.5, hasTravelHeading {
                yawRate = min(0.8, max(-0.8, motion.clockwiseYawRate))
                if let north = motion.accelerationNorth, let east = motion.accelerationEast {
                    let angle = heading * .pi / 180
                    let longitudinal = north * cos(angle) + east * sin(angle)
                    filteredAcceleration += (1 - exp(-dt / 0.12)) * (min(4, max(-5, longitudinal)) - filteredAcceleration)
                } else { filteredAcceleration = 0 }
            } else { filteredAcceleration = 0 }
            let oldSpeed = speed
            // At rest we wait for GPS to establish movement; sensor noise cannot launch the car.
            if gpsSpeed > 0.5 {
                let driftBound = min(8, 2 + 4 * max(0, cursor - lastFixTime))
                speed = min(100, min(gpsSpeed + driftBound, max(max(0, gpsSpeed - driftBound), speed + filteredAcceleration * dt)))
            } else { speed = 0 }
            let middleHeading = (heading + yawRate * dt * 90 / .pi) * .pi / 180
            let distance = (oldSpeed + speed) * 0.5 * dt
            position = Self.translate(position, north: distance * cos(middleHeading), east: distance * sin(middleHeading))
            heading = Self.normalize(heading + yawRate * dt * 180 / .pi)
            let decay = exp(-dt / 0.3)
            correctionNorth *= decay; correctionEast *= decay
            correctionHeading *= decay
            cursor += dt
        }
        point = position
        time = target
    }

    private static func normalize(_ degrees: Double) -> Double { (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) }
    private static func delta(from: Double, to: Double) -> Double { normalize(to - from + 180) - 180 }

    private static func offset(from a: GeoPoint, to b: GeoPoint) -> (north: Double, east: Double) {
        let r = Double.pi / 180
        return ((b.latitude - a.latitude) * r * 6_371_000,
                delta(from: a.longitude, to: b.longitude) * r * 6_371_000 * cos((a.latitude + b.latitude) * 0.5 * r))
    }

    /// Spherical displacement avoids a persistent tangent-plane origin drifting on long trips/dateline crossings.
    private static func translate(_ point: GeoPoint, north: Double, east: Double) -> GeoPoint {
        let distance = hypot(north, east)
        guard distance > 1e-8 else { return point }
        let angle = distance / 6_371_000, bearing = atan2(east, north)
        let lat = point.latitude * .pi / 180, lon = point.longitude * .pi / 180
        let nextLat = asin(min(1, max(-1, sin(lat) * cos(angle) + cos(lat) * sin(angle) * cos(bearing))))
        let nextLon = lon + atan2(sin(bearing) * sin(angle) * cos(lat), cos(angle) - sin(lat) * sin(nextLat))
        return GeoPoint(latitude: nextLat * 180 / .pi, longitude: normalize(nextLon * 180 / .pi + 180) - 180)
    }
}
