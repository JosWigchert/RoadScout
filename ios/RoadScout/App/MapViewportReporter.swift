import MapKit
import SwiftUI

struct MapViewportSnapshot: Equatable {
    let center: GeoPoint
    let distance: Double
    let heading: Double
    let pitch: Double
    let regionCenter: GeoPoint
    let latitudeDelta: Double
    let longitudeDelta: Double

    init(camera: MapCamera, region: MKCoordinateRegion) {
        center = GeoPoint(latitude: camera.centerCoordinate.latitude, longitude: camera.centerCoordinate.longitude)
        distance = camera.distance; heading = camera.heading; pitch = camera.pitch
        regionCenter = GeoPoint(latitude: region.center.latitude, longitude: region.center.longitude)
        latitudeDelta = region.span.latitudeDelta; longitudeDelta = region.span.longitudeDelta
    }

    var camera: MapCamera {
        MapCamera(centerCoordinate: center.coordinate, distance: distance, heading: heading, pitch: pitch)
    }

    var bounds: CameraBounds {
        CameraViewportQuery.viewport(center: regionCenter, latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
    }
}

/// Keep MapKit's callback/annotation/layout feedback out of SwiftUI's render pass.
/// Pending/throttling state is intentionally not observable view state.
@MainActor final class MapViewportReporter {
    private let delay: Duration
    private let uptime: () -> TimeInterval
    private var task: Task<Void, Never>?
    private var pending: MapViewportSnapshot?
    private var delivered: MapViewportSnapshot?
    private var lastAccepted: TimeInterval?
    private var generation = 0

    init(delay: Duration = .milliseconds(100), uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.delay = delay; self.uptime = uptime
    }

    func submit(_ snapshot: MapViewportSnapshot, minimumInterval: TimeInterval = 0,
                deliver: @escaping @MainActor (MapViewportSnapshot) -> Void) {
        if pending == snapshot { return }
        if minimumInterval > 0, let lastAccepted, uptime() - lastAccepted < minimumInterval { return }
        task?.cancel(); generation += 1
        pending = nil; task = nil
        guard snapshot != delivered else { return }
        pending = snapshot; lastAccepted = uptime()
        let token = generation, delay = delay
        task = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, !Task.isCancelled, self.generation == token else { return }
            self.pending = nil; self.delivered = snapshot; self.task = nil
            deliver(snapshot)
        }
    }

    func cancel() {
        generation += 1; task?.cancel(); task = nil
        pending = nil; delivered = nil; lastAccepted = nil
    }

    deinit { task?.cancel() }
}
