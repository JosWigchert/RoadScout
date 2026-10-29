import Foundation
import Observation

@MainActor @Observable final class TrafficModel {
    private(set) var map: TrafficMapResponse?
    private(set) var offer: TrafficOffer?
    private(set) var status: String?
    private(set) var checking = false
    @ObservationIgnored private let client: any TrafficProviding
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let uptime: () -> TimeInterval
    @ObservationIgnored private var policy = TrafficOfferPolicy()
    @ObservationIgnored private var mapTask: Task<Void, Never>?
    @ObservationIgnored private var routeTask: Task<Void, Never>?
    @ObservationIgnored private var lastMapKey = ""
    @ObservationIgnored private var lastMapTime = Date.distantPast
    @ObservationIgnored private var nextETA = Date.distantPast
    @ObservationIgnored private var nextAlternatives = Date.distantPast
    @ObservationIgnored private var routeID: String?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var mapGeneration = 0
    @ObservationIgnored private var endpoint = ""
    @ObservationIgnored private var visible = true
    @ObservationIgnored private var lastDecisionKey: String?
    @ObservationIgnored private var lastAlternativeCheck = Date.distantPast

    init(client: any TrafficProviding = TrafficClient(), now: @escaping () -> Date = Date.init,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.client = client; self.now = now; self.uptime = uptime
    }

    func fetchMap(bounds: CameraBounds, route: DrivingRoute?, endpoint: String) {
        expireMap()
        guard bounds.isValid else { return }
        let key = "\(endpoint)|\(bounds)|\(route?.id ?? "")"
        guard key != lastMapKey || now().timeIntervalSince(lastMapTime) >= 60 else { return }
        lastMapKey = key; lastMapTime = now(); mapGeneration += 1
        let token = mapGeneration
        mapTask?.cancel()
        mapTask = Task { [weak self, client] in
            do {
                let response = try await client.fetch(bounds: bounds, route: route, endpoint: endpoint)
                guard let self, !Task.isCancelled, token == self.mapGeneration else { return }
                self.map = response
            } catch {
                guard let self, !Task.isCancelled, token == self.mapGeneration else { return }
                self.status = String(localized: "Traffic unavailable or outside coverage.")
            }
        }
    }

    func consume(fix: LocationFix?, navigation: NavigationModel, endpoint: String, foreground: Bool) {
        visible = foreground
        if !foreground { policy.cancel(); offer = nil }
        if self.endpoint != endpoint { clear(); self.endpoint = endpoint }
        let selected = navigation.selectedRoute
        if routeID != selected?.id {
            generation += 1; routeTask?.cancel(); routeTask = nil; checking = false
            routeID = selected?.id; policy.cancel(); offer = nil; nextETA = .distantPast; nextAlternatives = .distantPast
            lastDecisionKey = nil; lastAlternativeCheck = .distantPast
        }
        guard navigation.isNavigating, !navigation.isPaused, let route = selected,
              let fix, fix.hasUsablePosition(at: now()), navigation.progress?.onRoute == true else { cancelOffer(); return }
        if policy.expired(now: now()) { cancelOffer() }
        if let offer, offer.route.traffic?.leadMeters ?? 0 < max(300, fix.speed * 30) { cancelOffer() }
        if let offer, foreground, uptime() >= offer.deadline { accept(fix: fix, navigation: navigation); return }
        guard routeTask == nil, route.traffic?.token != nil, now() >= nextETA else { return }
        var earlyDecision = false
        if let progress = navigation.progress, route.maneuvers.indices.contains(progress.maneuverIndex), fix.speed >= 2 {
            let maneuver = route.maneuvers[progress.maneuverIndex]
            let lead = progress.maneuverDistance / max(5, fix.speed)
            let key = route.id + maneuver.id
            if ["fork", "off_ramp", "merge"].contains(maneuver.type), (90...150).contains(lead),
               lastDecisionKey != key, now().timeIntervalSince(lastAlternativeCheck) >= 60 {
                earlyDecision = true; lastDecisionKey = key
            }
        }
        let check = foreground && (now() >= nextAlternatives || earlyDecision)
        nextETA = now().addingTimeInterval(60)
        if check { nextAlternatives = now().addingTimeInterval(300); lastAlternativeCheck = now() }
        refresh(route: route, fix: fix, navigation: navigation, check: check, accepting: nil)
    }

    private func refresh(route: DrivingRoute, fix: LocationFix, navigation: NavigationModel, check: Bool, accepting: String?) {
        let token = generation, endpoint = endpoint, meters = navigation.progress?.traveledMeters ?? 0
        checking = true
        routeTask = Task { [weak self, weak navigation, client] in
            do {
                let response = try await client.refresh(route: route, fix: fix, traveledMeters: meters, checkAlternatives: check, endpoint: endpoint)
                guard let self, let navigation, !Task.isCancelled, self.generation == token,
                      navigation.selectedRoute?.id == route.id else { return }
                self.routeTask = nil; self.checking = false
                guard navigation.isNavigating, !navigation.isPaused, navigation.progress?.onRoute == true else { self.cancelOffer(); return }
                guard response.routingEnabled, let seconds = response.remainingSeconds,
                      let expiry = response.expiresAt, expiry > self.now() else {
                    self.status = String(localized: "Live traffic routing unavailable. Using the last route estimate.")
                    self.cancelOffer(); return
                }
                let previous = navigation.progress?.remainingSeconds ?? seconds
                navigation.applyTrafficETA(routeID: route.id, seconds: seconds, expiresAt: expiry)
                if !check, seconds - previous >= max(120, previous * 0.1), self.now().timeIntervalSince(self.lastAlternativeCheck) >= 60 {
                    self.nextAlternatives = self.now().addingTimeInterval(15)
                    self.nextETA = self.now().addingTimeInterval(15)
                }
                self.status = String(localized: "Live traffic on covered roads")
                if let accepting {
                    guard self.visible, let candidate = response.alternatives.first(where: { $0.traffic?.corridorKey == accepting }),
                          fix.hasUsablePosition(at: self.now()), (candidate.traffic?.leadMeters ?? 0) >= max(300, fix.speed * 30) else { self.cancelOffer(); return }
                    self.cancelOffer(); navigation.adoptTrafficAlternative(candidate, fix: fix)
                    return
                }
                if check, self.visible, let candidate = response.alternatives.first {
                    self.policy.propose(route: candidate, currentSeconds: seconds, now: self.now(), uptime: self.uptime())
                    self.offer = self.policy.offer
                    // Confirm against the next fresh traffic snapshot before offering.
                    if self.offer == nil { self.nextAlternatives = self.now().addingTimeInterval(60) }
                } else if check {
                    self.cancelOffer()
                }
            } catch {
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.routeTask = nil; self.checking = false; self.cancelOffer()
                self.status = String(localized: "Traffic refresh unavailable; navigation continues.")
            }
        }
    }

    func accept(fix: LocationFix?, navigation: NavigationModel) {
        guard visible, let offer, let fix, fix.hasUsablePosition(at: now()),
              let route = navigation.selectedRoute, !policy.expired(now: now()), routeTask == nil else { return }
        policy.cancel(); self.offer = nil
        refresh(route: route, fix: fix, navigation: navigation, check: true, accepting: offer.corridorKey)
    }
    func reject() { policy.reject(uptime: uptime()); offer = nil }
    func cancelOffer() { policy.cancel(); offer = nil }
    func setVisible(_ visible: Bool) {
        self.visible = visible
        if !visible {
            generation += 1
            routeTask?.cancel(); routeTask = nil; checking = false
            cancelOffer()
        }
    }
    func endSession() { generation += 1; routeTask?.cancel(); routeTask = nil; checking = false; routeID = nil; status = nil; cancelOffer() }
    func clear() { endSession(); mapGeneration += 1; mapTask?.cancel(); mapTask = nil; map = nil; lastMapKey = ""; lastMapTime = .distantPast; status = nil }

    var visibleFeatures: [TrafficFeature] {
        (map?.features ?? []).filter { f in
            now().timeIntervalSince(f.observedAt) >= -60 && (f.expiresAt.map { $0 > now() } ?? (now().timeIntervalSince(f.observedAt) <= 180))
        }
    }
    func expireMap() {
        guard let map else { return }
        let features = visibleFeatures
        if features.count != map.features.count {
            self.map = TrafficMapResponse(sources: map.sources, features: features, routingEnabled: map.routingEnabled, truncated: map.truncated)
        }
    }
    deinit { mapTask?.cancel(); routeTask?.cancel() }
}
