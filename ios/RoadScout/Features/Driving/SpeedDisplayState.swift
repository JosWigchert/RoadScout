import Foundation

/// Presentation values shared by the speed and limit instruments. Inputs use SI units.
struct SpeedDisplayState {
    let speed: Double?
    let limit: Double?
    let unit: SpeedUnit

    init(metersPerSecond: Double?, limitMetersPerSecond: Double? = nil, unit: SpeedUnit) {
        speed = metersPerSecond.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        limit = limitMetersPerSecond.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.unit = unit
    }

    var isOverLimit: Bool {
        guard let speed, let limit else { return false }
        return speed > limit
    }

    var speedText: String { formatted(speed) }
    var limitText: String { formatted(limit) }

    private func formatted(_ value: Double?) -> String {
        guard let value else { return "—" }
        return unit.convert(metersPerSecond: value).formatted(.number.precision(.fractionLength(0)))
    }
}
