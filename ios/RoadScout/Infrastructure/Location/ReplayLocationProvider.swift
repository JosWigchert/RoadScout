import Foundation

struct ReplaySample: Codable, Sendable {
    let latitude: Double
    let longitude: Double
    let speed: Double
    let speedAccuracy: Double
    let horizontalAccuracy: Double
    let course: Double

    func fix(at date: Date) -> LocationFix {
        LocationFix(latitude: latitude, longitude: longitude, speed: speed,
                    speedAccuracy: speedAccuracy, horizontalAccuracy: horizontalAccuracy,
                    course: course, timestamp: date)
    }
}

@MainActor
final class ReplayLocationProvider: LocationProviding {
    var onEvent: ((LocationEvent) -> Void)?
    private let samples: [ReplaySample]
    private let interval: Duration
    private var task: Task<Void, Never>?

    init(samples: [ReplaySample], interval: Duration = .seconds(1)) {
        self.samples = samples
        self.interval = interval
    }

    static func bundled() throws -> ReplayLocationProvider {
        guard let url = Bundle.main.url(forResource: "free-drive", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return ReplayLocationProvider(samples: try JSONDecoder().decode(
            [ReplaySample].self, from: Data(contentsOf: url)))
    }

    func start() {
        stop()
        onEvent?(.access(.authorized))
        task = Task { [weak self] in
            guard let self else { return }
            for sample in samples {
                guard !Task.isCancelled else { return }
                onEvent?(.fix(sample.fix(at: Date())))
                do { try await Task.sleep(for: interval) } catch { return }
            }
            guard !Task.isCancelled else { return }
            onEvent?(.finished)
        }
    }

    static func navigationDemo() throws -> ReplayLocationProvider {
        guard let url = Bundle.main.url(forResource: "route-response", withExtension: "json"),
              let route = try RoadScoutRoutingProvider.decode(Data(contentsOf: url)).first else { throw RoutingError.invalidResponse }
        var samples: [ReplaySample] = []
        for (a, b) in zip(route.geometry, route.geometry.dropFirst()) {
            for step in 0..<5 {
                let t = Double(step) / 5
                samples.append(.init(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                     longitude: a.longitude + (b.longitude - a.longitude) * t,
                                     speed: 10, speedAccuracy: 1, horizontalAccuracy: 5,
                                     course: NavigationTracker.bearing(a, b)))
            }
        }
        let end = route.geometry.last!
        samples += Array(repeating: ReplaySample(latitude: end.latitude, longitude: end.longitude, speed: 0,
                                                 speedAccuracy: 1, horizontalAccuracy: 5, course: 90), count: 5)
        return ReplayLocationProvider(samples: samples)
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    deinit { task?.cancel() }
}
