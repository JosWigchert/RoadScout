import Foundation

/// Display-only heading state. Continuous angles prevent a 359° → 1° animation taking the long way.
struct DrivingHeadingPresentation {
    let timeConstant: TimeInterval
    private(set) var heading: Double = 0
    private(set) var arrowRotation: Double = 0
    private var mapHeading: Double = 0
    private var timestamp: Date?

    init(timeConstant: TimeInterval = 0.3) { self.timeConstant = max(0, timeConstant) }

    var cameraHeading: Double { Self.normalize(heading) }

    mutating func updateHeading(_ target: Double, at date: Date) {
        guard target.isFinite else { return }
        if let timestamp {
            let elapsed = date.timeIntervalSince(timestamp)
            guard elapsed > 0 else { return }
            let alpha = timeConstant > 0 ? 1 - exp(-elapsed / timeConstant) : 1
            heading += alpha * Self.shortestDelta(from: heading, to: target)
        } else {
            heading = Self.normalize(target)
        }
        timestamp = date
        updateArrow()
    }

    mutating func updateMapHeading(_ heading: Double) {
        guard heading.isFinite else { return }
        mapHeading = heading
        updateArrow()
    }

    mutating func resetHeading(_ heading: Double, at date: Date) {
        guard heading.isFinite else { return }
        self.heading = Self.normalize(heading)
        timestamp = date
        updateArrow()
    }

    private mutating func updateArrow() {
        arrowRotation += Self.shortestDelta(from: arrowRotation, to: heading - mapHeading)
    }

    private static func normalize(_ value: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: 360)
        return remainder < 0 ? remainder + 360 : remainder
    }

    private static func shortestDelta(from: Double, to: Double) -> Double {
        let delta = normalize(to - from)
        return delta > 180 ? delta - 360 : delta
    }
}
