import MapKit
import SwiftUI

/// Owns high-frequency driving camera/arrow state so display frames don't update
/// the planning sheet, navigation coordinator or enforcement evaluators.
struct DrivingMapSurface<Overlays: MapContent>: View {
    @Binding var position: MapCameraPosition
    @Binding var following: Bool
    let driving: Bool
    let motion: DrivingMotionModel
    let fix: LocationFix?
    let source: DrivingSource
    let fallbackHeading: Double
    let cameraEnded: (MapViewportSnapshot) -> Void
    @MapContentBuilder let overlays: () -> Overlays
    @State private var drivingCamera: MapCameraPosition = .automatic
    @State private var heading = DrivingHeadingPresentation()
    @State private var viewportReporter = MapViewportReporter()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Map(position: driving ? $drivingCamera : $position) {
            overlays()
            if let fix {
                Annotation(source != .live ? String(localized: "Simulated position") : String(localized: "Your position"),
                    coordinate: motion.pose?.point.coordinate ?? fix.coordinate, anchor: .center) {
                    DrivingPositionArrow(rotation: heading.arrowRotation)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControls { MapCompass(); MapScaleView() }
        .onMapCameraChange(frequency: .continuous) { context in
            guard scenePhase == .active else { return }
            withoutAnimation { heading.updateMapHeading(context.camera.heading) }
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            guard scenePhase == .active else { return }
            viewportReporter.submit(MapViewportSnapshot(camera: context.camera, region: context.region),
                                    minimumInterval: driving && following ? 1 : 0) { snapshot in
                // Once the initial automatic viewport is resolved, annotation updates
                // must not cause MapKit to refit the camera and request new data again.
                if !driving, position == .automatic { position = .camera(snapshot.camera) }
                cameraEnded(snapshot)
            }
        }
        .onChange(of: drivingCamera) { _, value in
            if value.positionedByUser { following = false }
        }
        .onChange(of: motion.pose) { _, _ in updatePose() }
        .onChange(of: fix) { _, _ in if motion.pose == nil { updatePose() } }
        .onChange(of: following) { _, value in if value { updatePose() } }
        .onChange(of: driving) { _, value in
            viewportReporter.cancel()
            if value { updatePose() }
        }
        .onChange(of: position) { _, value in
            if driving, !following { drivingCamera = value }
        }
        .onAppear { updatePose() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { updatePose() }
            else { viewportReporter.cancel() }
        }
        .onDisappear { viewportReporter.cancel() }
    }

    private func updatePose() {
        guard scenePhase == .active, driving,
              let coordinate = motion.pose?.point.coordinate ?? fix?.coordinate else { return }
        withoutAnimation {
            let bearing = motion.pose?.heading ?? fallbackHeading
            heading.resetHeading(bearing, at: Date())
            if following {
                drivingCamera = .camera(MapCamera(centerCoordinate: coordinate, distance: 650, heading: bearing, pitch: 45))
            } else if drivingCamera.camera == nil && !drivingCamera.positionedByUser {
                drivingCamera = position
            }
        }
    }

    private func withoutAnimation(_ update: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, update)
    }
}
