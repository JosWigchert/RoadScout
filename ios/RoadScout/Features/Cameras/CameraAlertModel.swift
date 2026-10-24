import Foundation
import Observation

@MainActor @Observable
final class CameraAlertModel {
    private(set) var cameras: [CameraRecord] = []
    private(set) var zones: [AverageSpeedZone] = []
    private(set) var metadata: CameraDatasetMetadata?
    private(set) var alert: CameraWarning?
    private(set) var isUsingCache = false
    private(set) var statusMessage: String?
    private(set) var cachedBounds: CameraBounds?
    private(set) var fetchedAt: Date?

    @ObservationIgnored private let client: any CameraProviding
    @ObservationIgnored private let cache: any CameraCaching
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var requestedScope: CameraCacheScope?
    @ObservationIgnored private var loadedScope: CameraCacheScope?
    @ObservationIgnored private var requestedAt: Date?
    @ObservationIgnored private var evaluator = CameraAlertEvaluator()

    init(client: any CameraProviding = CameraClient(), cache: any CameraCaching = CameraDiskCache(),
         now: @escaping () -> Date = Date.init) {
        self.client = client; self.cache = cache; self.now = now
    }

    func fetch(bounds: CameraBounds, route: DrivingRoute?, endpoint: String) {
        guard bounds.isValid else { return }
        let scope = CameraCacheScope(endpoint: endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
                                     bounds: bounds, routeFingerprint: CameraRouteGeometry.fingerprint(route))
        if let prior = requestedScope, prior.endpoint == scope.endpoint,
           prior.routeFingerprint == scope.routeFingerprint,
           prior.bounds.center.distance(to: bounds.center) < 500,
           abs(prior.bounds.north - prior.bounds.south - (bounds.north - bounds.south)) < 0.001,
           abs(prior.bounds.east - prior.bounds.west - (bounds.east - bounds.west)) < 0.001,
           let requestedAt, now().timeIntervalSince(requestedAt) < 30 { return }
        if requestedScope?.endpoint != scope.endpoint { clear() }
        if loadedScope?.routeFingerprint != scope.routeFingerprint { stop() }
        task?.cancel(); generation += 1
        let current = generation
        requestedScope = scope; requestedAt = now()
        task = Task { [weak self, client, cache] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self, self.generation == current else { return }
            // Exact scope only: an earlier viewport/route is never treated as coverage of this query.
            let cached = try? await cache.load(scope: scope)
            guard !Task.isCancelled, self.generation == current else { return }
            if let cached { self.apply(cached, cached: true) }
            else if self.loadedScope != scope {
                self.cameras = []; self.zones = []; self.metadata = nil
                self.loadedScope = nil; self.cachedBounds = nil; self.fetchedAt = nil
                self.isUsingCache = false; self.alert = nil
            }
            do {
                let response = try await client.fetch(bounds: bounds, route: route, endpoint: scope.endpoint)
                guard !Task.isCancelled, self.generation == current else { return }
                let entry = CameraCacheEntry(scope: scope, fetchedAt: self.now(), response: response)
                self.apply(entry, cached: false)
                do { try await cache.save(entry) }
                catch {
                    guard self.generation == current else { return }
                    self.statusMessage = "Camera data loaded; local cache could not be saved."
                }
            } catch {
                guard !Task.isCancelled, self.generation == current else { return }
                if self.loadedScope == scope {
                    self.isUsingCache = true
                    self.statusMessage = "Camera service unavailable. Cached query area only; saved \(self.fetchedAt?.formatted() ?? "at an unknown time")."
                } else {
                    self.statusMessage = "Camera service unavailable. No cached data for this query area and route."
                }
            }
        }
    }

    private func apply(_ entry: CameraCacheEntry, cached: Bool) {
        cameras = entry.response.cameras; zones = entry.response.averageSpeedZones
        var currentMetadata = entry.response.dataset
        let checkAge = currentMetadata.lastCheckedAt.map { now().timeIntervalSince($0) }
        let sourceAge = currentMetadata.sourceUpdatedAt.map { now().timeIntervalSince($0) }
        currentMetadata.stale = currentMetadata.stale || checkAge == nil || (checkAge ?? 0) > 86_400
            || (checkAge ?? 0) < -600 || (sourceAge ?? 0) > 86_400
        metadata = currentMetadata; loadedScope = entry.scope
        cachedBounds = entry.scope.bounds; fetchedAt = entry.fetchedAt; isUsingCache = cached
        var messages = entry.response.warnings?.map(\.message) ?? []
        if entry.response.truncated { messages.append("Camera results are incomplete for this query.") }
        if cached { messages.append("Cached query area only; saved \(entry.fetchedAt.formatted()).") }
        if currentMetadata.stale { messages.append("Mapped camera dataset is stale.") }
        statusMessage = messages.isEmpty ? nil : messages.joined(separator: " ")
    }

    func consume(fix: LocationFix?, heading: Double, route: DrivingRoute?, progress: NavigationProgress?,
                 isDriving: Bool, settings: CameraWarningSettings) -> CameraWarning? {
        let audible = evaluator.consume(cameras: cameras, zones: zones, fix: fix, heading: heading,
                                        route: route, progress: progress,
                                        routeEvidenceValid: loadedScope?.routeFingerprint == CameraRouteGeometry.fingerprint(route),
                                        isDriving: isDriving, settings: settings, now: now())
        alert = evaluator.alert
        return audible
    }

    func stop() { evaluator.reset(); alert = nil }
    func clear() {
        task?.cancel(); task = nil; generation += 1
        stop(); cameras = []; zones = []; metadata = nil; isUsingCache = false; statusMessage = nil
        requestedScope = nil; loadedScope = nil; requestedAt = nil; cachedBounds = nil; fetchedAt = nil
    }
}
