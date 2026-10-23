import Foundation
import Observation

enum DrivingSource: String, CaseIterable, Identifiable {
    case live, replay, navigationReplay
    var id: String { rawValue }
}

enum DrivingStatus {
    case ready, requestingPermission, acquiring, driving, stopped, permissionDenied
    case restricted, servicesDisabled, unavailable, replayFinished, backgroundStopped, replayUnavailable

    var title: String {
        switch self {
        case .ready: String(localized: "Ready to drive")
        case .requestingPermission: String(localized: "Allow location to start")
        case .acquiring: String(localized: "Finding GPS signal…")
        case .driving: String(localized: "Free drive")
        case .stopped: String(localized: "Session stopped")
        case .permissionDenied: String(localized: "Location access denied")
        case .restricted: String(localized: "Location access restricted")
        case .servicesDisabled: String(localized: "Location Services are off")
        case .unavailable: String(localized: "GPS speed unavailable")
        case .replayFinished: String(localized: "Replay finished")
        case .backgroundStopped: String(localized: "Stopped while in background")
        case .replayUnavailable: String(localized: "Replay could not be loaded")
        }
    }
}

@MainActor @Observable
final class DrivingModel {
    private(set) var isDriving = false
    private(set) var fix: LocationFix?
    private(set) var heading: Double = 0
    private(set) var metersPerSecond: Double?
    private(set) var status: DrivingStatus = .ready
    private(set) var source: DrivingSource = .live
    @ObservationIgnored private var provider: (any LocationProviding)?
    @ObservationIgnored private let makeProvider: (DrivingSource) throws -> any LocationProviding
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var processor = SpeedProcessor()
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var session = UUID()
    @ObservationIgnored private var latestTimestamp: Date?

    init(makeProvider: @escaping (DrivingSource) throws -> any LocationProviding = { source in
        switch source {
        case .live: CoreLocationProvider()
        case .replay: try ReplayLocationProvider.bundled()
        case .navigationReplay: try ReplayLocationProvider.navigationDemo()
        }
    }, now: @escaping () -> Date = Date.init) {
        self.makeProvider = makeProvider
        self.now = now
    }

    func start(source: DrivingSource) {
        stop()
        self.source = source
        do {
            let provider = try makeProvider(source)
            self.provider = provider
            isDriving = true
            status = .acquiring
            let token = session
            provider.onEvent = { [weak self] event in
                guard let self, isDriving, session == token else { return }
                receive(event)
            }
            provider.start()
            if isDriving {
                expiryTask = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(1)) } catch { return }
                        guard let self, isDriving else { return }
                        refreshFreshness()
                    }
                }
            }
        } catch {
            status = .replayUnavailable
        }
    }

    func stop() {
        session = UUID()
        provider?.onEvent = nil
        provider?.stop()
        provider = nil
        expiryTask?.cancel()
        expiryTask = nil
        processor.reset()
        latestTimestamp = nil
        metersPerSecond = nil
        fix = nil
        heading = 0
        isDriving = false
        status = .stopped
    }

    func enterBackground() {
        guard isDriving else { return }
        stop()
        status = .backgroundStopped
    }

    func refreshFreshness() {
        guard isDriving else { return }
        processor.expire(at: now())
        metersPerSecond = processor.metersPerSecond
        if let fix, !fix.hasUsablePosition(at: now()) { self.fix = nil }
        if metersPerSecond == nil, status == .driving { status = .unavailable }
    }

    private func receive(_ event: LocationEvent) {
        switch event {
        case .access(.authorized): status = .acquiring
        case .access(.notDetermined): status = .requestingPermission
        case .access(let access):
            stop()
            switch access {
            case .servicesDisabled: status = .servicesDisabled
            case .denied: status = .permissionDenied
            default: status = .restricted
            }
        case .fix(let newFix):
            if let latestTimestamp, newFix.timestamp <= latestTimestamp { return }
            if newFix.timestamp <= now().addingTimeInterval(1) { latestTimestamp = newFix.timestamp }
            processor.ingest(newFix, now: now())
            metersPerSecond = processor.metersPerSecond
            if newFix.hasUsablePosition(at: now()) {
                fix = newFix
                if newFix.course.isFinite, (0..<360).contains(newFix.course), newFix.speed > 2 {
                    heading = newFix.course
                }
            } else {
                fix = nil
            }
            status = metersPerSecond == nil ? .unavailable : .driving
        case .heading(let heading):
            if heading.isFinite, (0..<360).contains(heading), (metersPerSecond ?? 0) <= 2 {
                self.heading = heading
            }
        case .failure:
            processor.reset()
            metersPerSecond = nil
            fix = nil
            status = .unavailable
        case .finished:
            stop()
            status = .replayFinished
        }
    }

    deinit { expiryTask?.cancel() }
}
