import AVFoundation
import CoreLocation
import Foundation
import Testing
@testable import RoadScout

@MainActor private final class BackgroundLocationManager: DrivingLocationManaging {
    weak var delegate: (any CLLocationManagerDelegate)?
    var authorizationStatus: CLAuthorizationStatus = .authorizedWhenInUse
    var desiredAccuracy = 0.0
    var distanceFilter = 0.0
    var activityType: CLActivityType = .other
    var headingFilter = 0.0
    var allowsBackgroundLocationUpdates = false
    var pausesLocationUpdatesAutomatically = true
    var showsBackgroundLocationIndicator = false
    var locationStarts = 0, locationStops = 0, headingStarts = 0, headingStops = 0, permissionRequests = 0
    func requestWhenInUseAuthorization() { permissionRequests += 1 }
    func startUpdatingLocation() { locationStarts += 1 }
    func stopUpdatingLocation() { locationStops += 1 }
    func startUpdatingHeading() { headingStarts += 1 }
    func stopUpdatingHeading() { headingStops += 1 }
}

@MainActor private func awaitBackground(_ condition: () async -> Bool) async {
    for _ in 0..<500 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
    #expect(await condition())
}

@MainActor struct BackgroundLocationPolicyTests {
    @Test func whenInUseSessionKeepsGPSButStopsCompassWhileBackgrounded() async {
        let manager = BackgroundLocationManager()
        let provider = CoreLocationProvider(manager: manager, supportsBackgroundLocation: true,
            servicesEnabled: { true }, headingAvailable: { true })
        provider.start()
        await awaitBackground { manager.locationStarts == 1 }
        #expect(manager.permissionRequests == 0)
        #expect(manager.allowsBackgroundLocationUpdates)
        #expect(manager.showsBackgroundLocationIndicator)
        #expect(!manager.pausesLocationUpdatesAutomatically)
        #expect(manager.activityType == .automotiveNavigation)
        #expect(manager.headingStarts == 1)
        provider.setBackgrounded(true)
        #expect(manager.locationStarts == 1)
        #expect(manager.allowsBackgroundLocationUpdates)
        #expect(manager.headingStops >= 1)
        provider.setBackgrounded(false)
        #expect(manager.locationStarts == 1)
        #expect(manager.headingStarts == 2)
        provider.stop()
        #expect(!manager.allowsBackgroundLocationUpdates)
        #expect(!manager.showsBackgroundLocationIndicator)
    }

    @Test func permissionRequestsAreForegroundOnlyAndUseWhenInUse() async {
        let manager = BackgroundLocationManager()
        manager.authorizationStatus = .notDetermined
        let provider = CoreLocationProvider(manager: manager, supportsBackgroundLocation: true,
            servicesEnabled: { true }, headingAvailable: { false })
        provider.start()
        await awaitBackground { manager.permissionRequests == 1 }
        provider.setBackgrounded(true)
        #expect(manager.permissionRequests == 1)
        #expect(manager.locationStarts == 0)
        manager.authorizationStatus = .authorizedWhenInUse
        provider.setBackgrounded(false)
        #expect(manager.locationStarts == 1)
        #expect(manager.allowsBackgroundLocationUpdates)
        provider.stop()
    }

    @Test func revocationAndDisabledServicesClearBackgroundFlags() async {
        let manager = BackgroundLocationManager()
        let provider = CoreLocationProvider(manager: manager, supportsBackgroundLocation: true,
            servicesEnabled: { true }, headingAvailable: { false })
        var denied = false
        provider.onEvent = { if case .access(.denied) = $0 { denied = true } }
        provider.start()
        await awaitBackground { manager.locationStarts == 1 }
        manager.authorizationStatus = .denied
        provider.setBackgrounded(true)
        #expect(denied)
        #expect(!manager.allowsBackgroundLocationUpdates)
        #expect(!manager.showsBackgroundLocationIndicator)
        let unavailable = CoreLocationProvider(manager: manager, supportsBackgroundLocation: true,
            servicesEnabled: { false }, headingAvailable: { false })
        var disabled = false
        unavailable.onEvent = { if case .access(.servicesDisabled) = $0 { disabled = true } }
        unavailable.start()
        await awaitBackground { disabled }
        #expect(!manager.allowsBackgroundLocationUpdates)
    }

    @Test func missingCapabilityNeverEnablesBackgroundUpdates() async {
        let manager = BackgroundLocationManager()
        let provider = CoreLocationProvider(manager: manager, supportsBackgroundLocation: false,
            servicesEnabled: { true }, headingAvailable: { false })
        provider.start()
        await awaitBackground { manager.locationStarts == 1 }
        #expect(!manager.allowsBackgroundLocationUpdates)
        provider.stop()
    }

    @Test func processedApplicationDeclaresLocationAndAudioBackgroundModes() throws {
        let modes = try #require(Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])
        #expect(modes.contains("location"))
        #expect(modes.contains("audio"))
        let purpose = try #require(Bundle.main.object(forInfoDictionaryKey: "NSLocationWhenInUseUsageDescription") as? String)
        #expect(purpose.contains("locked"))
        #expect(Bundle.main.object(forInfoDictionaryKey: "NSLocationAlwaysAndWhenInUseUsageDescription") == nil)
    }
}

@MainActor private final class BackgroundClock {
    var date = sampleFix().timestamp
    var uptime = 100.0
    func advance(_ seconds: Double) { date += seconds; uptime += seconds }
}
@MainActor private final class BackgroundFrameClock: DrivingFrameClock {
    var running = false
    var frame: (() -> Void)?
    func start(_ frame: @escaping () -> Void) { running = true; self.frame = frame }
    func stop() { running = false; frame = nil }
}
@MainActor private final class BackgroundMotionProvider: DrivingMotionProviding {
    var onSample: ((DrivingMotionSample) -> Void)?
    var starts = 0, stops = 0
    func start() { starts += 1 }
    func stop() { stops += 1 }
}
@MainActor private final class BackgroundAudio: AudioAnnouncing {
    var spoken: [String] = []
    var stops = 0
    func speak(_ text: String, language: String) { spoken.append(text) }
    func stop() { stops += 1 }
}
private struct BackgroundAudioSession: SpeechAudioSessionProviding {
    func setActive(_ active: Bool) async throws { }
}
@MainActor private final class BackgroundSpeechOutput: SpeechSynthesizing {
    var isSpeaking = false
    var spoken: [String] = []
    func speak(_ utterance: AVSpeechUtterance) { spoken.append(utterance.speechString); isSpeaking = true }
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool { isSpeaking = false; return true }
}
private actor BackgroundCameraCache: CameraCaching {
    func load(scope: CameraCacheScope) -> CameraCacheEntry? { nil }
    func save(_ entry: CameraCacheEntry) { }
}
private actor BackgroundCameraClient: CameraProviding {
    var response: CameraResponse
    private(set) var requests = 0
    init(response: CameraResponse) { self.response = response }
    func fetch(bounds: CameraBounds, route: DrivingRoute?, endpoint: String) -> CameraResponse {
        requests += 1
        return response
    }
}
private actor BackgroundRouter: RoutingProviding {
    var routes: [DrivingRoute] = []
    private(set) var requests = 0
    private(set) var lastRequest: RouteRequest?
    func setRoutes(_ routes: [DrivingRoute]) { self.routes = routes }
    func routes(for request: RouteRequest) -> [DrivingRoute] { requests += 1; lastRequest = request; return routes }
}

@MainActor private func backgroundFix(_ point: GeoPoint, clock: BackgroundClock, course: Double = 0) -> LocationFix {
    LocationFix(latitude: point.latitude, longitude: point.longitude, speed: 10,
        speedAccuracy: 0.5, horizontalAccuracy: 5, course: course, timestamp: clock.date)
}

@MainActor struct BackgroundDrivingTests {
    @Test func firstFixCanStartNavigationWhileLockedAndDiscardedViewStateCannotStealCallbacks() throws {
        let clock = BackgroundClock(), audio = BackgroundAudio(), output = BackgroundSpeechOutput()
        let navigation = NavigationModel(audio: audio, now: { clock.date })
        try navigation.loadDemo()
        let route = try #require(navigation.selectedRoute)
        let provider = TestLocationProvider()
        let model = DrivingModel(makeProvider: { _ in provider }, now: { clock.date })
        let cameras = CameraAlertModel()
        let speech = SpeechAnnouncer(audioSession: SpeechAudioSessionController(session: BackgroundAudioSession()), synthesizer: output)
        let session = DrivingSessionCoordinator(driving: model, navigation: navigation, cameras: cameras, speech: speech, now: { clock.date })
        session.configure(DrivingSessionSettings(camerasEnabled: false))
        model.start(source: .live)
        session.requestNavigationStart()
        session.enterBackground()
        // SwiftUI can construct/discard candidate State values using the same injected models.
        _ = DrivingSessionCoordinator(driving: model, navigation: navigation, cameras: cameras, speech: speech, now: { clock.date })
        provider.send(.fix(backgroundFix(route.geometry[0], clock: clock)))
        #expect(navigation.isNavigating)
        #expect(!navigation.isPaused)
        let spoken = audio.spoken.count
        navigation.muted = true
        clock.advance(4)
        provider.send(.fix(backgroundFix(route.geometry[1], clock: clock)))
        #expect(audio.spoken.count == spoken)
        #expect(navigation.progress?.traveledMeters ?? 0 > 20)
        let oldCallback = provider.onEvent
        model.stop()
        clock.advance(1)
        oldCallback?(.fix(backgroundFix(route.geometry[2], clock: clock)))
        #expect(navigation.isPaused)
        #expect(!model.isDriving)
        #expect(model.fix == nil)
    }

    @Test func pendingRouteCalculationAndStartFinishInBackgroundWithoutViewUpdates() async throws {
        let clock = BackgroundClock(), router = BackgroundRouter()
        let navigation = NavigationModel(audio: BackgroundAudio(), provider: { _ in router }, now: { clock.date })
        try navigation.loadDemo()
        let route = try #require(navigation.selectedRoute)
        await router.setRoutes([route])
        navigation.preview(Destination(name: "Background destination", point: route.geometry.last!), fix: nil,
            endpoint: "https://fixture.invalid", preferences: .init(avoidTolls: true), objective: .moreCorners,
            maxExtraDurationPercent: 50)
        let provider = TestLocationProvider()
        let model = DrivingModel(makeProvider: { _ in provider }, now: { clock.date })
        let session = DrivingSessionCoordinator(driving: model, navigation: navigation, cameras: CameraAlertModel(),
            speech: SpeechAnnouncer(audioSession: SpeechAudioSessionController(session: BackgroundAudioSession()), synthesizer: BackgroundSpeechOutput()),
            now: { clock.date })
        session.configure(DrivingSessionSettings(camerasEnabled: false))
        model.start(source: .live)
        session.requestNavigationStart()
        session.enterBackground()
        provider.send(.fix(backgroundFix(route.geometry[0], clock: clock)))
        await awaitBackground { navigation.isNavigating }
        #expect(await router.requests == 1)
        let request = try #require(await router.lastRequest)
        #expect(request.origin == route.geometry[0])
        #expect(request.preferences.avoidTolls)
        #expect(request.objective == .moreCorners)
        #expect(request.maxExtraDurationPercent == 50)
        #expect(model.isBackgrounded)
        model.stop()
    }

    @Test func motionStopsWhileLockedAndForegroundSeedsFromLatestBackgroundFix() throws {
        let clock = BackgroundClock(), frames = BackgroundFrameClock(), sensors = BackgroundMotionProvider()
        let provider = TestLocationProvider()
        let motion = DrivingMotionModel(makeProvider: { sensors }, clock: frames,
            uptime: { clock.uptime }, now: { clock.date })
        let model = DrivingModel(makeProvider: { _ in provider }, now: { clock.date }, motion: motion)
        model.start(source: .live)
        provider.send(.fix(sampleFix()))
        #expect(frames.running)
        model.enterBackground()
        #expect(model.isDriving)
        #expect(!frames.running)
        #expect(sensors.stops == 1)
        #expect(motion.pose == nil)
        clock.advance(20)
        let point = GeoPoint(latitude: 52.001, longitude: 5)
        provider.send(.fix(backgroundFix(point, clock: clock)))
        #expect(model.fix?.latitude == point.latitude)
        #expect(motion.pose == nil)
        model.enterForeground()
        #expect(provider.starts == 1)
        #expect(frames.running)
        #expect(sensors.starts == 2)
        #expect(try #require(motion.pose).point.distance(to: point) < 0.01)
        model.stop()
    }

    @Test func staleFixIsNotExtrapolatedAfterUnlockAndEndedSessionStaysStopped() {
        let clock = BackgroundClock(), frames = BackgroundFrameClock(), sensors = BackgroundMotionProvider()
        let provider = TestLocationProvider()
        let motion = DrivingMotionModel(makeProvider: { sensors }, clock: frames,
            uptime: { clock.uptime }, now: { clock.date })
        let model = DrivingModel(makeProvider: { _ in provider }, now: { clock.date }, motion: motion)
        model.start(source: .live)
        provider.send(.fix(sampleFix()))
        model.enterBackground()
        clock.advance(60)
        model.enterForeground()
        #expect(model.fix == nil)
        #expect(motion.pose == nil)
        model.enterBackground()
        model.stop()
        model.enterForeground()
        #expect(!frames.running)
        #expect(!model.isDriving)
        #expect(provider.starts == 1)
    }

    @Test func backgroundCallbacksDriveGuidanceCameraDataAndArrivalWithoutAView() async throws {
        let clock = BackgroundClock(), audio = BackgroundAudio(), output = BackgroundSpeechOutput()
        let navigation = NavigationModel(audio: audio, now: { clock.date })
        try navigation.loadDemo()
        let route = try #require(navigation.selectedRoute)
        let camera = CameraRecord(id: "background-camera", coordinate: route.geometry[2], kind: "fixed",
            maxSpeedKph: 80, directionDegrees: 0, association: "relation", sourceIDs: ["fixture"], status: "mapped",
            routeDistanceMeters: route.cumulativeMeters[2], routeLateralMeters: 0, routeMatch: "confirmed")
        let client = BackgroundCameraClient(response: CameraResponse(dataset: CameraDatasetMetadata(version: "fixture",
            coverage: "NL", lastCheckedAt: clock.date, sourceUpdatedAt: clock.date, stale: false),
            cameras: [camera], averageSpeedZones: [], truncated: false))
        let cameras = CameraAlertModel(client: client, cache: BackgroundCameraCache(), now: { clock.date }, debounce: .zero)
        let provider = TestLocationProvider()
        let model = DrivingModel(makeProvider: { _ in provider }, now: { clock.date })
        let speech = SpeechAnnouncer(audioSession: SpeechAudioSessionController(session: BackgroundAudioSession()), synthesizer: output)
        let session = DrivingSessionCoordinator(driving: model, navigation: navigation, cameras: cameras, speech: speech, now: { clock.date })
        session.configure(DrivingSessionSettings(endpoint: "https://fixture.invalid"))
        model.start(source: .live)
        provider.send(.fix(backgroundFix(route.geometry[0], clock: clock)))
        session.requestNavigationStart()
        let departureCount = audio.spoken.count
        session.enterBackground()
        await awaitBackground { cameras.alert?.confident == true }
        await awaitBackground { !output.spoken.isEmpty }
        #expect(model.isDriving)
        #expect(navigation.isNavigating)
        #expect(!navigation.isPaused)
        #expect(await client.requests > 0)
        clock.advance(4)
        provider.send(.fix(backgroundFix(route.geometry[1], clock: clock)))
        #expect(navigation.progress?.traveledMeters ?? 0 > 20)
        #expect(audio.spoken.count > departureCount)
        #expect(cameras.alert?.confident == true)
        let routeID = navigation.selectedRoute?.id
        session.enterForeground()
        #expect(navigation.selectedRoute?.id == routeID)
        #expect(navigation.isNavigating)
        session.enterBackground()
        clock.advance(1)
        provider.send(.fix(backgroundFix(route.geometry.last!, clock: clock, course: 90)))
        clock.advance(1)
        provider.send(.fix(backgroundFix(route.geometry.last!, clock: clock, course: 90)))
        #expect(navigation.progress?.arrived == true)
        #expect(!navigation.isNavigating)
        model.stop()
        #expect(provider.stops == 1)
        #expect(!output.isSpeaking)
    }

    @Test func backgroundOffRouteAutomaticallyAdoptsFirstNewRouteAndPermissionLossPausesIt() async throws {
        let clock = BackgroundClock(), router = BackgroundRouter(), audio = BackgroundAudio()
        let navigation = NavigationModel(audio: audio, provider: { _ in router }, now: { clock.date })
        try navigation.loadDemo()
        let original = try #require(navigation.selectedRoute)
        let replacement = try DrivingRoute(geometry: original.geometry, distanceMeters: original.distanceMeters,
            durationSeconds: original.durationSeconds, maneuvers: original.maneuvers, id: "background-reroute")
        await router.setRoutes([replacement, original])
        let provider = TestLocationProvider()
        let model = DrivingModel(makeProvider: { _ in provider }, now: { clock.date })
        let cameras = CameraAlertModel()
        let speech = SpeechAnnouncer(audioSession: SpeechAudioSessionController(session: BackgroundAudioSession()), synthesizer: BackgroundSpeechOutput())
        let session = DrivingSessionCoordinator(driving: model, navigation: navigation, cameras: cameras, speech: speech, now: { clock.date })
        session.configure(DrivingSessionSettings(camerasEnabled: false))
        model.start(source: .live)
        provider.send(.fix(backgroundFix(original.geometry[0], clock: clock)))
        session.requestNavigationStart()
        session.enterBackground()
        for delta in [1.0, 3.0] {
            clock.advance(delta)
            provider.send(.fix(backgroundFix(GeoPoint(latitude: 52.095, longitude: 5.12), clock: clock)))
        }
        await awaitBackground { navigation.selectedRoute?.id == "background-reroute" }
        #expect(await router.requests == 1)
        #expect(navigation.isNavigating)
        #expect(!navigation.isPaused)
        provider.send(.access(.denied))
        #expect(!model.isDriving)
        #expect(navigation.isPaused)
        #expect(model.status == .permissionDenied)
        session.enterForeground()
        #expect(!model.isDriving)
        #expect(provider.starts == 1)
    }
}
