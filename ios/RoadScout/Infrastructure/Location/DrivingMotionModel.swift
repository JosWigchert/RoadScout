import Foundation
import Observation
import QuartzCore

@MainActor protocol DrivingFrameClock: AnyObject {
    func start(_ frame: @escaping () -> Void)
    func stop()
}

@MainActor final class DrivingDisplayClock: DrivingFrameClock {
    @MainActor private final class Target: NSObject {
        weak var owner: DrivingDisplayClock?
        @objc func tick() { owner?.frame?() }
    }
    private var link: CADisplayLink?
    private var frame: (() -> Void)?
    private let target = Target()

    func start(_ frame: @escaping () -> Void) {
        stop()
        self.frame = frame
        target.owner = self
        let link = CADisplayLink(target: target, selector: #selector(Target.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() { link?.invalidate(); link = nil; frame = nil }
    isolated deinit { link?.invalidate() }
}

@MainActor @Observable final class DrivingMotionModel {
    private(set) var pose: DrivingPose?
    @ObservationIgnored private var estimator = DrivingMotionEstimator()
    @ObservationIgnored private let makeProvider: () -> any DrivingMotionProviding
    @ObservationIgnored private let clock: any DrivingFrameClock
    @ObservationIgnored private let uptime: () -> TimeInterval
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var provider: (any DrivingMotionProviding)?
    @ObservationIgnored private var active = false
    @ObservationIgnored private var session = UUID()

    init(makeProvider: @escaping () -> any DrivingMotionProviding = { CoreMotionProvider() },
         clock: any DrivingFrameClock = DrivingDisplayClock(),
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         now: @escaping () -> Date = Date.init) {
        self.makeProvider = makeProvider; self.clock = clock; self.uptime = uptime; self.now = now
    }

    func start(live: Bool) {
        stop()
        active = true
        let token = session
        if live {
            let provider = makeProvider()
            self.provider = provider
            provider.onSample = { [weak self] sample in
                guard let self, self.active, self.session == token else { return }
                self.estimator.ingest(sample, uptime: self.uptime())
            }
            provider.start()
        }
        clock.start { [weak self] in
            guard let self, self.active, self.session == token else { return }
            self.pose = self.estimator.pose(at: self.uptime())
        }
    }

    func ingest(_ fix: LocationFix) {
        guard active else { return }
        estimator.ingest(fix, now: now(), uptime: uptime())
        pose = estimator.pose(at: uptime())
    }

    func stop() {
        active = false; session = UUID()
        clock.stop()
        provider?.onSample = nil
        provider?.stop(); provider = nil
        estimator.reset(); pose = nil
    }
}
