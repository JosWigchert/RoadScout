import Foundation

enum SpeedUnit: String, CaseIterable, Identifiable {
    case kilometersPerHour, milesPerHour
    var id: String { rawValue }
    var symbol: String { self == .kilometersPerHour ? "km/h" : "mph" }

    func convert(metersPerSecond: Double) -> Double {
        metersPerSecond * (self == .kilometersPerHour ? 3.6 : 2.2369362921)
    }

    static var localeDefault: SpeedUnit {
        Locale.current.measurementSystem == .us || Locale.current.region?.identifier == "GB"
            ? .milesPerHour : .kilometersPerHour
    }
}

struct SpeedProcessor {
    private(set) var metersPerSecond: Double?
    private var lastTimestamp: Date?
    private var lastValidTimestamp: Date?

    mutating func reset() { self = SpeedProcessor() }

    mutating func ingest(_ fix: LocationFix, now: Date) {
        guard lastTimestamp.map({ fix.timestamp > $0 }) ?? true else { return }
        guard fix.hasUsablePosition(at: now), fix.speed.isFinite, fix.speed >= 0,
              fix.speedAccuracy.isFinite, (0...3).contains(fix.speedAccuracy) else {
            metersPerSecond = nil
            lastValidTimestamp = nil
            // A future timestamp must not poison the ordering of subsequent fixes.
            if fix.timestamp <= now { lastTimestamp = fix.timestamp }
            return
        }
        let previousTime = lastValidTimestamp
        let previousSpeed = metersPerSecond
        lastTimestamp = fix.timestamp
        lastValidTimestamp = fix.timestamp
        guard fix.speed >= 0.5 else {
            metersPerSecond = 0
            return
        }
        guard let previousSpeed, let previousTime,
              fix.timestamp.timeIntervalSince(previousTime) <= 5,
              abs(fix.speed - previousSpeed) < 3 else {
            metersPerSecond = fix.speed
            return
        }
        let delta = fix.timestamp.timeIntervalSince(previousTime)
        let alpha = 1 - exp(-delta / 0.4)
        metersPerSecond = previousSpeed + alpha * (fix.speed - previousSpeed)
    }

    mutating func expire(at now: Date) {
        if let lastValidTimestamp, now.timeIntervalSince(lastValidTimestamp) > 5 {
            metersPerSecond = nil
            self.lastValidTimestamp = nil
        }
    }
}
