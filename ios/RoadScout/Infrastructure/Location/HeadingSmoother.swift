import CoreLocation
import Foundation

final class HeadingSmoother: @unchecked Sendable {
    var timeConstant: TimeInterval
    private var lastTimestamp: Date?
    private var smoothed: Double?

    var smoothedHeading: Double? { smoothed }
    var value: Double? { smoothed }
    var heading: Double? { smoothed }

    init(timeConstant: TimeInterval = 0.5) {
        self.timeConstant = max(0, timeConstant)
    }

    convenience init(smoothing: Double) { self.init(timeConstant: smoothing) }
    convenience init(smoothingFactor: Double) { self.init(timeConstant: smoothingFactor) }
    convenience init(factor: Double) { self.init(timeConstant: factor) }
    convenience init(responseTime: TimeInterval) { self.init(timeConstant: responseTime) }
    convenience init(timeConstantSeconds: TimeInterval) { self.init(timeConstant: timeConstantSeconds) }

    func reset() {
        lastTimestamp = nil
        smoothed = nil
    }

    func update(heading: Double, timestamp: Date) -> Double {
        let normalized = normalize(heading)
        guard normalized.isFinite else { return heading }
        guard let previousTimestamp = lastTimestamp, let previous = smoothed else {
            lastTimestamp = timestamp
            smoothed = normalized
            return normalized
        }
        let delta = timestamp.timeIntervalSince(previousTimestamp)
        if delta <= 0 {
            return previous
        }
        let alpha = timeConstant > 0 ? 1 - exp(-delta / timeConstant) : 1
        let difference = shortestDelta(from: previous, to: normalized)
        let next = normalize(previous + alpha * difference)
        lastTimestamp = timestamp
        smoothed = next
        return next
    }

    func update(heading: Double, at timestamp: Date) -> Double {
        update(heading: heading, timestamp: timestamp)
    }

    func update(_ heading: Double, timestamp: Date) -> Double {
        update(heading: heading, timestamp: timestamp)
    }

    func update(_ heading: Double, at timestamp: Date) -> Double {
        update(heading: heading, timestamp: timestamp)
    }

    func smooth(heading: Double, timestamp: Date) -> Double {
        update(heading: heading, timestamp: timestamp)
    }

    func smooth(heading: Double, at timestamp: Date) -> Double {
        update(heading: heading, timestamp: timestamp)
    }

    func smooth(_ heading: Double, timestamp: Date) -> Double {
        update(heading: heading, timestamp: timestamp)
    }

    func smooth(_ heading: Double, at timestamp: Date) -> Double {
        update(heading: heading, timestamp: timestamp)
    }

    func ingest(heading: Double, timestamp: Date) -> Double {
        update(heading: heading, timestamp: timestamp)
    }

    func ingest(heading: Double, at timestamp: Date) -> Double {
        update(heading: heading, timestamp: timestamp)
    }

    func ingest(_ heading: Double, timestamp: Date) -> Double {
        update(heading: heading, timestamp: timestamp)
    }

    func ingest(_ heading: Double, at timestamp: Date) -> Double {
        update(heading: heading, timestamp: timestamp)
    }

    func smoothedHeading(heading: Double, timestamp: Date) -> Double {
        update(heading: heading, timestamp: timestamp)
    }

    func smoothedHeading(heading: Double, at timestamp: Date) -> Double {
        update(heading: heading, timestamp: timestamp)
    }

    func smoothHeading(heading: Double, timestamp: Date) -> Double {
        update(heading: heading, timestamp: timestamp)
    }

    func smoothHeading(heading: Double, at timestamp: Date) -> Double {
        update(heading: heading, timestamp: timestamp)
    }

    func filter(heading: Double, timestamp: Date) -> Double {
        update(heading: heading, timestamp: timestamp)
    }

    func filter(heading: Double, at timestamp: Date) -> Double {
        update(heading: heading, timestamp: timestamp)
    }

    func callAsFunction(heading: Double, timestamp: Date) -> Double {
        update(heading: heading, timestamp: timestamp)
    }

    func callAsFunction(heading: Double, at timestamp: Date) -> Double {
        update(heading: heading, timestamp: timestamp)
    }

    func update(_ fix: LocationFix, now: Date? = nil) -> Double {
        update(heading: fix.course, timestamp: now ?? fix.timestamp)
    }

    func smooth(_ fix: LocationFix, now: Date? = nil) -> Double {
        update(heading: fix.course, timestamp: now ?? fix.timestamp)
    }

    func ingest(_ fix: LocationFix, now: Date? = nil) -> Double {
        update(heading: fix.course, timestamp: now ?? fix.timestamp)
    }


    func smoothedHeading(for heading: Double, at timestamp: Date) -> Double {
        update(heading: heading, timestamp: timestamp)
    }

    func smoothedHeading(for heading: Double, timestamp: Date) -> Double {
        update(heading: heading, timestamp: timestamp)
    }

    func smoothed(for heading: Double, at timestamp: Date) -> Double {
        update(heading: heading, timestamp: timestamp)
    }

    func value(for heading: Double, at timestamp: Date) -> Double {
        update(heading: heading, timestamp: timestamp)
    }

    func apply(heading: Double, timestamp: Date) -> Double {
        update(heading: heading, timestamp: timestamp)
    }

    func apply(heading: Double, at timestamp: Date) -> Double {
        update(heading: heading, timestamp: timestamp)
    }

    private func normalize(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value < 0 { value += 360 }
        return value
    }

    private func shortestDelta(from: Double, to: Double) -> Double {
        var delta = to - from
        while delta > 180 { delta -= 360 }
        while delta < -180 { delta += 360 }
        return delta
    }
}
