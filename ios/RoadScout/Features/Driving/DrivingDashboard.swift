import SwiftUI

struct DrivingDashboard: View {
    let presentation: DrivingGuidancePresentation
    let unit: SpeedUnit
    let muted: Bool
    let hasRoute: Bool
    let hasFix: Bool
    let isDemo: Bool
    let compact: Bool
    let end: () -> Void
    let toggleMute: () -> Void
    let start: () -> Void
    let retry: () -> Void
    let information: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            if compact {
                HStack(spacing: 16) {
                    maneuverHeader
                    controls
                }
            } else {
                maneuverHeader
            }
            if let message = presentation.message {
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if presentation.showsTravelMetrics {
                Divider()
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    HStack(spacing: 8) {
                        metric(presentation.arrival(at: context.date)?.formatted(date: .omitted, time: .shortened) ?? "—", label: "arrival")
                        metric("\(max(1, Int(ceil((presentation.remainingSeconds ?? 0) / 60)))) min", label: "remaining")
                        metric(PlaceDistanceFormatter.string(presentation.remainingMeters ?? 0, unit: unit), label: "distance")
                    }
                }
            }
            if !compact { controls }
        }
        .padding(compact ? 14 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassFloatingControl(cornerRadius: 28)
        .accessibilityElement(children: .contain)
    }

    private var maneuverHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: presentation.symbol)
                .font(.system(size: compact ? 28 : 32, weight: .semibold))
                .frame(width: 42, height: 48)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.maneuverDistance.map { PlaceDistanceFormatter.string($0, unit: unit) } ?? presentation.title)
                    .font(compact ? .headline : .title2.bold())
                    .monospacedDigit()
                if let instruction = presentation.instruction {
                    Text(instruction).font(.subheadline.weight(.medium)).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if presentation.mode == .loading { ProgressView().controlSize(.small) }
            if isDemo {
                Text("DEMO").font(.caption2.bold())
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(.orange, in: Capsule()).foregroundStyle(.black)
                    .accessibilityLabel("Simulated GPS demo")
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button(action: end) {
                Label("End", systemImage: "xmark")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16).frame(minHeight: 44)
                    .foregroundStyle(.red)
                    .background(.red.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("End drive")
            .accessibilityHint("Stops driving and returns to planning")
            if !compact { Spacer(minLength: 0) }
            if presentation.canStart {
                Button(presentation.mode == .paused ? "Resume" : "Start", action: start)
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                    .frame(minHeight: 44).disabled(!hasFix)
            } else if presentation.canRetry {
                Button("Retry", action: retry).buttonStyle(.bordered)
                    .frame(minHeight: 44).disabled(!hasFix)
            }
            if hasRoute {
                Button(action: toggleMute) {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .buttonStyle(MapIconButtonStyle())
                .accessibilityLabel(muted ? "Unmute guidance" : "Mute guidance")
                Button(action: information) { Image(systemName: "ellipsis") }
                    .buttonStyle(MapIconButtonStyle())
                    .accessibilityLabel("Route information")
            }
        }
        .fixedSize(horizontal: compact, vertical: false)
    }

    private func metric(_ value: String, label: LocalizedStringKey) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.system(.title3, design: .rounded, weight: .semibold))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

#Preview("Driving · free-drive bottom card") {
    DrivingDashboard(presentation: DrivingGuidancePresentation(route: nil, progress: nil,
        isNavigating: false, isPaused: false, isLoading: false, hasDestination: false,
        destinationName: nil, message: nil), unit: .kilometersPerHour, muted: false,
        hasRoute: false, hasFix: true, isDemo: false, compact: false,
        end: {}, toggleMute: {}, start: {}, retry: {}, information: {})
        .padding()
}
