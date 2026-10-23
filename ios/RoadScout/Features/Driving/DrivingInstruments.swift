import SwiftUI

private enum DrivingInstrumentMetrics {
    static let diameter: CGFloat = 94
}

struct DrivingSpeedometer: View {
    let display: SpeedDisplayState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var diameter = DrivingInstrumentMetrics.diameter

    var body: some View {
        Text(display.speedText)
            .font(.system(.largeTitle, design: .rounded, weight: .bold))
            .monospacedDigit()
            .contentTransition(reduceMotion ? .identity : .numericText())
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .padding(12)
            .frame(width: diameter, height: diameter)
            .background(.background, in: Circle())
            .overlay {
                Circle().strokeBorder(display.isOverLimit ? Color.red : Color.primary.opacity(0.12),
                                      lineWidth: display.isOverLimit ? 5 : 1)
            }
            .overlay(alignment: .bottomTrailing) {
                if display.isOverLimit {
                    Image(systemName: "exclamationmark")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(.red, in: Circle())
                        .overlay(Circle().strokeBorder(.background, lineWidth: 2))
                        .accessibilityHidden(true)
                }
            }
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: display.speedText)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: display.isOverLimit)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(display.speed == nil
                ? String(localized: "GPS speed unavailable")
                : String(localized: "Speed \(display.speedText) \(display.unit.symbol)"))
            .accessibilityValue(display.isOverLimit ? String(localized: "Over speed limit") : "")
    }
}

struct DrivingSpeedLimit: View {
    let display: SpeedDisplayState
    @ScaledMetric(relativeTo: .largeTitle) private var diameter = DrivingInstrumentMetrics.diameter

    var body: some View {
        VStack(spacing: 4) {
            Text(display.limitText)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .padding(8)
                .frame(width: diameter, height: diameter)
                .foregroundStyle(.black)
                .background(.white, in: Circle())
                .overlay(Circle().strokeBorder(display.limit == nil ? Color.gray : Color.red, lineWidth: 4))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display.limit == nil
            ? String(localized: "Speed limit unknown")
            : String(localized: "Speed limit \(display.limitText) \(display.unit.symbol)"))
    }
}

#Preview("Speed · below limit") {
    DrivingSpeedometer(display: SpeedDisplayState(metersPerSecond: 12.5,
        limitMetersPerSecond: 50 / 3.6, unit: .kilometersPerHour))
        .padding()
}

#Preview("Speed · over limit · synthetic") {
    HStack(spacing: 32) {
        DrivingSpeedometer(display: SpeedDisplayState(metersPerSecond: 60 / 3.6,
            limitMetersPerSecond: 50 / 3.6, unit: .kilometersPerHour))
        DrivingSpeedLimit(display: SpeedDisplayState(metersPerSecond: 60 / 3.6,
            limitMetersPerSecond: 50 / 3.6, unit: .kilometersPerHour))
    }
    .padding()
}

#Preview("Speed · mph") {
    DrivingSpeedometer(display: SpeedDisplayState(metersPerSecond: 26.8224, unit: .milesPerHour))
        .padding()
}

#Preview("Speed · unavailable") {
    DrivingSpeedometer(display: SpeedDisplayState(metersPerSecond: nil, unit: .kilometersPerHour))
        .padding()
}
