import Foundation

struct DrivingSessionSettings: Equatable {
    var endpoint = AppConfiguration.routingAPIBaseURL
    var camerasEnabled = true
    var cameraAudioEnabled = true
    var warningDistance = 500.0
    var trafficEnabled = false
}

/// Foreground and locked/background guidance consume provider callbacks directly,
/// independent of SwiftUI observation, rendering or view-scoped tasks.
@MainActor final class DrivingSessionCoordinator {
    private let driving: DrivingModel
    private let navigation: NavigationModel
    private let cameras: CameraAlertModel
    private let speech: SpeechAnnouncer
    let traffic: TrafficModel
    private let now: () -> Date
    private var settings = DrivingSessionSettings()
    private var lastCameraWarningID: String?
    private enum PendingStart { case selectedPreview, needsRoute, calculatedRoute }
    private var pendingStart: PendingStart?
    private var bound = false

    init(driving: DrivingModel, navigation: NavigationModel, cameras: CameraAlertModel,
         speech: SpeechAnnouncer, traffic: TrafficModel = TrafficModel(), now: @escaping () -> Date = Date.init) {
        self.driving = driving; self.navigation = navigation; self.cameras = cameras
        self.speech = speech; self.now = now
        self.traffic = traffic
    }

    // SwiftUI may construct and discard candidate State values. Wire callbacks
    // only when the retained coordinator is activated, never during its init.
    private func bind() {
        guard !bound else { return }
        bound = true
        driving.onFix = { [weak self] in self?.consume($0) }
        driving.onSessionEnded = { [weak self] in self?.sessionEnded() }
        navigation.onRouteChanged = { [weak self] in self?.routeChanged() }
        navigation.onMuteChanged = { [weak self] muted in self?.speech.setMuted(muted) }
        cameras.onDataChanged = { [weak self] in self?.evaluateCameras() }
        speech.setMuted(navigation.muted)
    }

    func configure(_ settings: DrivingSessionSettings) {
        bind()
        let previous = self.settings
        self.settings = settings
        if !settings.camerasEnabled {
            cameras.clear(); speech.cancelCameraWarnings()
        } else {
            if previous.endpoint != settings.endpoint { cameras.clear() }
            refreshCameras()
        }
        if !settings.cameraAudioEnabled { speech.cancelCameraWarnings() }
        evaluateCameras()
        if !settings.trafficEnabled { traffic.clear() }
    }

    func requestNavigationStart() {
        bind()
        pendingStart = navigation.selectedRoute == nil ? .needsRoute : .selectedPreview
        tryStarting(with: driving.fix)
    }

    func retryRoute() {
        bind()
        pendingStart = .calculatedRoute
        navigation.refreshFromGPS(driving.fix)
    }

    func enterBackground() {
        bind()
        traffic.setVisible(false)
        driving.enterBackground()
        if !driving.isDriving {
            navigation.pause(); cameras.stop(); speech.stop()
        }
    }

    func enterForeground() {
        bind()
        traffic.setVisible(true)
        driving.enterForeground()
        if driving.isDriving { consume(driving.fix) }
    }

    func refreshCameras() {
        guard driving.isDriving, driving.source == .live, settings.camerasEnabled,
              let fix = driving.fix, fix.hasUsablePosition(at: now()) else { return }
        cameras.fetch(bounds: CameraViewportQuery.around(GeoPoint(latitude: fix.latitude, longitude: fix.longitude)),
                      route: navigation.selectedRoute, endpoint: settings.endpoint)
    }

    func evaluateCameras() {
        guard driving.isDriving else { return }
        let cue = cameras.consume(fix: driving.fix, heading: driving.heading, route: navigation.selectedRoute,
            progress: navigation.progress, isDriving: true,
            settings: CameraWarningSettings(enabled: settings.camerasEnabled,
                audioEnabled: settings.cameraAudioEnabled && !navigation.muted && driving.source == .live,
                warningDistanceMeters: settings.warningDistance))
        if lastCameraWarningID != cameras.alert?.id || cameras.alert?.confident != true {
            speech.cancelCameraWarnings()
            lastCameraWarningID = cameras.alert?.id
        }
        if let cue { speech.speakCamera(cue.announcement, language: Locale.preferredLanguages.first ?? "en-US") }
    }

    private func consume(_ fix: LocationFix?) {
        guard driving.isDriving else { return }
        tryStarting(with: fix)
        navigation.consume(fix)
        refreshCameras()
        evaluateCameras()
        if settings.trafficEnabled, driving.source == .live {
            traffic.consume(fix: fix, navigation: navigation, endpoint: settings.endpoint, foreground: !driving.isBackgrounded)
            if !driving.isBackgrounded, let fix {
                traffic.fetchMap(bounds: CameraViewportQuery.around(GeoPoint(latitude: fix.latitude, longitude: fix.longitude)),
                    route: navigation.selectedRoute, endpoint: settings.endpoint)
            }
        }
    }

    private func tryStarting(with fix: LocationFix?) {
        guard driving.isDriving, let intent = pendingStart, let fix, fix.hasUsablePosition(at: now()) else { return }
        switch intent {
        case .needsRoute:
            pendingStart = .calculatedRoute
            if !navigation.isLoading { navigation.refreshFromGPS(fix) }
        case .selectedPreview:
            pendingStart = .calculatedRoute
            if navigation.startPreviewOrRecalculate(fix: fix) { pendingStart = nil }
        case .calculatedRoute:
            guard navigation.selectedRoute != nil, !navigation.isLoading else { return }
            navigation.start(fix: fix)
            if navigation.isNavigating || navigation.progress?.arrived == true { pendingStart = nil }
        }
    }

    private func routeChanged() {
        traffic.clear()
        speech.cancelCameraWarnings(); cameras.stop(); lastCameraWarningID = nil
        if navigation.selectedRoute != nil { tryStarting(with: driving.fix) }
        refreshCameras()
    }

    private func sessionEnded() {
        traffic.endSession()
        pendingStart = nil; lastCameraWarningID = nil
        navigation.pause(); cameras.stop(); speech.stop()
    }
}
