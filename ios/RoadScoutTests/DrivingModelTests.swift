import Foundation
import Testing
@testable import RoadScout

@MainActor
final class TestLocationProvider: LocationProviding {
    var onEvent: ((LocationEvent) -> Void)?
    var starts = 0
    var stops = 0
    var backgroundStates: [Bool] = []
    func start() { starts += 1 }
    func stop() { stops += 1 }
    func setBackgrounded(_ backgrounded: Bool) { backgroundStates.append(backgrounded) }
    func send(_ event: LocationEvent) { onEvent?(event) }
}

@MainActor
struct DrivingModelTests {
    @Test func explicitSessionsAndLateCallbacks() {
        let provider = TestLocationProvider()
        let fix = sampleFix()
        let model = DrivingModel(makeProvider: { _ in provider }, now: { fix.timestamp })
        #expect(provider.starts == 0)
        #expect(!model.isDriving)
        model.start(source: .live)
        #expect(provider.starts == 1)
        provider.send(.fix(fix))
        #expect(model.metersPerSecond == 10)
        let oldCallback = provider.onEvent
        model.stop()
        #expect(provider.stops == 1)
        #expect(model.metersPerSecond == nil)
        #expect(model.fix == nil)
        model.start(source: .live)
        oldCallback?(.fix(fix))
        #expect(model.metersPerSecond == nil)
        model.stop()
    }

    @Test func permissionDenialStopsProviderAndKeepsUnknownSpeed() {
        let provider = TestLocationProvider()
        let model = DrivingModel(makeProvider: { _ in provider })
        model.start(source: .live)
        provider.send(.access(.notDetermined))
        #expect(model.status == .requestingPermission)
        provider.send(.access(.denied))
        #expect(!model.isDriving)
        #expect(model.status == .permissionDenied)
        #expect(provider.stops == 1)
        #expect(model.metersPerSecond == nil)
    }

    @Test func freshnessExpiresWithoutNewGPSCallbacks() {
        let provider = TestLocationProvider()
        let fix = sampleFix()
        var date = fix.timestamp
        let model = DrivingModel(makeProvider: { _ in provider }, now: { date })
        model.start(source: .live)
        provider.send(.fix(fix))
        date = date.addingTimeInterval(6)
        model.refreshFreshness()
        #expect(model.metersPerSecond == nil)
        #expect(model.fix == nil)
        #expect(model.status == .unavailable)
        model.stop()
    }

    @Test func liveDriveContinuesInBackgroundAndForegroundDoesNotRestartProvider() {
        let provider = TestLocationProvider()
        let model = DrivingModel(makeProvider: { _ in provider })
        model.start(source: .live)
        model.enterBackground()
        #expect(model.isDriving)
        #expect(model.isBackgrounded)
        #expect(provider.stops == 0)
        #expect(provider.backgroundStates == [true])
        model.enterForeground()
        #expect(!model.isBackgrounded)
        #expect(provider.starts == 1)
        #expect(provider.backgroundStates == [true, false])
        model.stop()
        #expect(provider.stops == 1)
    }

    @Test func demosStopInBackgroundAndForegroundNeverRestartsStoppedSession() {
        let provider = TestLocationProvider()
        let model = DrivingModel(makeProvider: { _ in provider })
        model.start(source: .replay)
        model.enterBackground()
        #expect(!model.isDriving)
        #expect(model.status == .backgroundStopped)
        #expect(provider.stops == 1)
        model.enterForeground()
        #expect(provider.starts == 1)
        #expect(!model.isDriving)
    }

    @Test func sessionCannotBeStartedWhileAlreadyBackgrounded() {
        let provider = TestLocationProvider()
        let model = DrivingModel(makeProvider: { _ in provider })
        model.enterBackground()
        model.start(source: .live)
        #expect(provider.starts == 0)
        #expect(!model.isDriving)
        model.enterForeground()
        #expect(provider.starts == 0)
    }

    @Test func failureAndReplayCompletionClearSpeed() {
        let provider = TestLocationProvider()
        let fix = sampleFix()
        let model = DrivingModel(makeProvider: { _ in provider }, now: { fix.timestamp })
        model.start(source: .replay)
        provider.send(.fix(fix))
        provider.send(.failure)
        #expect(model.metersPerSecond == nil)
        #expect(model.status == .unavailable)
        provider.send(.finished)
        #expect(!model.isDriving)
        #expect(model.status == .replayFinished)
    }

    @Test func outOfOrderFixAfterPoorAccuracyIsIgnored() {
        let provider = TestLocationProvider()
        let model = DrivingModel(makeProvider: { _ in provider }, now: { sampleFix(time: 2).timestamp })
        model.start(source: .live)
        var poorFix = sampleFix(time: 2)
        poorFix.horizontalAccuracy = 100
        provider.send(.fix(poorFix))
        provider.send(.fix(sampleFix(time: 1)))
        #expect(model.fix == nil)
        #expect(model.metersPerSecond == nil)
        model.stop()
    }

    @Test func sourceLoadFailureIsVisible() {
        let model = DrivingModel(makeProvider: { _ in throw CocoaError(.fileNoSuchFile) })
        model.start(source: .replay)
        #expect(!model.isDriving)
        #expect(model.status == .replayUnavailable)
    }

    @Test func movingCourseTakesPriorityOverCompass() {
        let provider = TestLocationProvider()
        var fix = sampleFix()
        fix.course = 90
        let model = DrivingModel(makeProvider: { _ in provider }, now: { fix.timestamp })
        model.start(source: .live)
        provider.send(.fix(fix))
        provider.send(.heading(180))
        #expect(model.heading == 90)
        model.stop()
    }
}
