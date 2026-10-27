import MapKit
import SwiftUI

struct WeatherRouteLine: View {
    let state: WeatherModel.State
    let unit: SpeedUnit

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Checking weather…")
            }
            .font(.caption).foregroundStyle(.secondary)
        case .loaded(let response):
            Label {
                Text(summary(for: response))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            } icon: {
                Image(systemName: response.recommendation == .unavailable ? "cloud.slash" : (response.hasRainRisk ? "cloud.rain.fill" : "cloud.sun.fill"))
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(response.recommendation == .rainRisk ? .blue : .secondary)
            .accessibilityLabel(summary(for: response))
            if let generatedAt = response.generatedAt {
                Text("Checked \(generatedAt.formatted(date: .omitted, time: .shortened)) · 15-min rain / hourly probability")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let warning = response.warnings.first {
                Text(warning.message).font(.caption2).foregroundStyle(.secondary)
            }
        case .expired:
            Label("Weather expired — recalculate", systemImage: "clock.badge.exclamationmark")
                .font(.caption).foregroundStyle(.secondary)
        case .unavailable(let message):
            Label(message, systemImage: "cloud.slash")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private func summary(for response: WeatherResponse) -> String {
        if response.recommendation == .unavailable { return "Forecast Unavailable" }
        guard let summary = response.summary else {
            return response.recommendation == .rainRisk ? "Rain Risk" : "Roof Down · low forecast rain risk"
        }
        switch response.recommendation {
        case .rainRisk:
            var text = "Rain Risk · \(Int(summary.maxProbabilityPercent.rounded()))% · \(intensity(summary.maxIntensityMmPerHour))"
            if let worstAt = summary.worstAt {
                text += " around \(worstAt.formatted(date: .omitted, time: .shortened))"
            }
            return text
        case .roofDown:
            return "Roof Down · low forecast rain risk"
        case .unavailable:
            return "Weather unavailable"
        }
    }

    private func intensity(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(value < 1 ? 1 : 0)))) mm/h"
    }
}

struct WeatherMapContent: MapContent {
    let response: WeatherResponse

    @MapContentBuilder var body: some MapContent {
        ForEach(Array(response.segments.enumerated()), id: \.offset) { _, segment in
            if segment.geometry.count >= 2 {
                MapPolyline(coordinates: segment.geometry.map(\.coordinate))
                    .stroke(.blue.opacity(0.85), style: StrokeStyle(lineWidth: 6, dash: [7, 5]))
            }
        }
        if let worst = response.summary?.worstCoordinate {
            Annotation("Expected rain", coordinate: worst.coordinate) {
                Image(systemName: "cloud.rain.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(.blue, in: Circle())
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                    .accessibilityLabel("Expected rain along the selected route")
            }
            .annotationTitles(.hidden)
        }
    }
}

struct WeatherAttribution: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Weather data by Open-Meteo.com")
                .font(.caption)
            Text("CC BY 4.0 · forecast guidance, not a guarantee. Planning only.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

#Preview("Weather · rain risk") {
    WeatherRouteLine(state: .loaded(WeatherResponse(
        routeToken: "preview", provider: WeatherProviderInfo(id: "open-meteo", name: "Open-Meteo"),
        recommendation: .rainRisk,
        summary: WeatherSummary(maxProbabilityPercent: 70, maxIntensityMmPerHour: 0.8,
                                worstAt: Date(), sampleCount: 40, rainRiskSampleCount: 5))),
        unit: .kilometersPerHour).padding()
}

#Preview("Weather · dry") {
    WeatherRouteLine(state: .loaded(WeatherResponse(routeToken: "preview", recommendation: .roofDown,
        summary: WeatherSummary(sampleCount: 40))), unit: .kilometersPerHour).padding()
}
