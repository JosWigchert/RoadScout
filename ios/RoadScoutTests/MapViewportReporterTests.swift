import Foundation
import MapKit
import SwiftUI
import Testing
@testable import RoadScout

@MainActor private func viewport(_ latitude: Double = 52.09, heading: Double = 0) -> MapViewportSnapshot {
    MapViewportSnapshot(camera: MapCamera(centerCoordinate: CLLocationCoordinate2D(latitude: latitude, longitude: 5.12),
        distance: 650, heading: heading, pitch: 45),
        region: MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: latitude, longitude: 5.12),
            span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.06)))
}

@MainActor private func awaitViewport(_ condition: () -> Bool) async {
    for _ in 0..<500 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
    #expect(condition())
}

@MainActor struct MapViewportReporterTests {
    @Test func callbackBurstDeliversOnlyLatestSnapshotOutsideSubmit() async {
        let reporter = MapViewportReporter(delay: .milliseconds(5))
        var delivered: [MapViewportSnapshot] = []
        reporter.submit(viewport()) { delivered.append($0) }
        reporter.submit(viewport(52.1)) { delivered.append($0) }
        let latest = viewport(52.11)
        reporter.submit(latest) { delivered.append($0) }
        #expect(delivered.isEmpty)
        await awaitViewport { delivered.count == 1 }
        #expect(delivered == [latest])
    }

    @Test func identicalDeliveredViewportDoesNotReportAgain() async {
        let reporter = MapViewportReporter(delay: .milliseconds(5))
        var delivered: [MapViewportSnapshot] = []
        let snapshot = viewport()
        reporter.submit(snapshot) { delivered.append($0) }
        await awaitViewport { delivered.count == 1 }
        reporter.submit(snapshot) { delivered.append($0) }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(delivered.count == 1)
    }

    @Test func returningToDeliveredViewportCancelsObsoletePendingReport() async {
        let reporter = MapViewportReporter(delay: .milliseconds(5))
        var delivered: [MapViewportSnapshot] = []
        let original = viewport()
        reporter.submit(original) { delivered.append($0) }
        await awaitViewport { delivered.count == 1 }
        reporter.submit(viewport(52.2)) { delivered.append($0) }
        reporter.submit(original) { delivered.append($0) }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(delivered == [original])
    }

    @Test func cancellationDropsOldViewReportsAndAllowsNewSession() async {
        let reporter = MapViewportReporter(delay: .milliseconds(5))
        var delivered: [MapViewportSnapshot] = []
        let snapshot = viewport()
        reporter.submit(snapshot) { delivered.append($0) }
        reporter.cancel()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(delivered.isEmpty)
        reporter.submit(snapshot) { delivered.append($0) }
        await awaitViewport { delivered.count == 1 }
    }

    @Test func followCameraReportsAreLimitedToOncePerSecond() async {
        var time = 100.0
        let reporter = MapViewportReporter(delay: .milliseconds(5), uptime: { time })
        var delivered: [MapViewportSnapshot] = []
        reporter.submit(viewport(), minimumInterval: 1) { delivered.append($0) }
        time = 100.1
        reporter.submit(viewport(52.1), minimumInterval: 1) { delivered.append($0) }
        await awaitViewport { delivered.count == 1 }
        #expect(delivered[0] == viewport())
        time = 101
        reporter.submit(viewport(52.1), minimumInterval: 1) { delivered.append($0) }
        await awaitViewport { delivered.count == 2 }
        #expect(delivered[1] == viewport(52.1))
    }

    @Test func smallViewportNoiseDoesNotChangeQuantizedQueryBounds() {
        let a = viewport()
        let b = viewport(52.09001, heading: 15)
        #expect(a != b)
        #expect(a.bounds == b.bounds)
        #expect(b.camera.heading == 15)
    }
}
