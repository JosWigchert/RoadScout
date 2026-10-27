import Foundation
import Observation

/// In-memory weather state per route token. Planning only: no UI, audio or trip
/// persistence. Requests are deduplicated by token and departure minute, cached
/// for 15 minutes and superseded per generation so stale responses are dropped.
@MainActor @Observable final class WeatherModel {
    enum State: Equatable {
        case idle
        case loading
        case loaded(WeatherResponse)
        case expired
        case unavailable(String)

        var response: WeatherResponse? {
            if case .loaded(let response) = self { return response }
            return nil
        }

        var isLoading: Bool {
            if case .loading = self { return true }
            return false
        }
    }

    static let ttl: TimeInterval = 900

    private(set) var states: [String: State] = [:]
    @ObservationIgnored private let client: any WeatherProviding
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var entries: [String: Entry] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var generations: [String: Int] = [:]

    private struct Entry {
        var minute: Int
        var fetchedAt: Date
        var state: State
    }

    init(client: any WeatherProviding = WeatherClient(), now: @escaping () -> Date = Date.init) {
        self.client = client
        self.now = now
    }

    func state(for route: DrivingRoute) -> State {
        guard let token = route.weatherToken, !token.isEmpty else { return .idle }
        if let expiry = route.weatherExpiresAt, expiry <= now() { return .expired }
        return state(forToken: token)
    }

    func state(forToken token: String) -> State {
        let state = states[token] ?? .idle
        if let response = state.response, let expiry = response.expiresAt, expiry <= now() { return .expired }
        return state
    }

    func load(route: DrivingRoute, endpoint: String, departureAt: Date = Date()) {
        guard let token = route.weatherToken, !token.isEmpty else { return }
        load(token: token, endpoint: endpoint, departureAt: departureAt)
    }

    /// Requests weather for every route card that carries a token.
    func loadAll(routes: [DrivingRoute], endpoint: String, departureAt: Date = Date()) {
        for route in routes { load(route: route, endpoint: endpoint, departureAt: departureAt) }
    }

    func clear() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        entries.removeAll()
        generations.removeAll()
        states.removeAll()
    }

    func expireCachedForecasts() {
        for (token, entry) in entries {
            if case .loaded(let response) = entry.state,
               (response.expiresAt.map { $0 <= now() } ?? false) || now().timeIntervalSince(entry.fetchedAt) >= Self.ttl {
                states[token] = .expired
            }
        }
    }

    private func load(token: String, endpoint: String, departureAt: Date) {
        let minute = Self.minuteKey(departureAt)
        if let entry = entries[token], entry.minute == minute {
            switch entry.state {
            case .loading:
                return
            case .expired:
                states[token] = entry.state
                return
            case .loaded where now().timeIntervalSince(entry.fetchedAt) < Self.ttl:
                states[token] = entry.state
                return
            default:
                break
            }
        }
        let generation = (generations[token] ?? 0) + 1
        generations[token] = generation
        tasks[token]?.cancel()
        entries[token] = Entry(minute: minute, fetchedAt: now(), state: .loading)
        states[token] = .loading
        tasks[token] = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await self.client.fetch(routeToken: token, endpoint: endpoint, departureAt: departureAt)
                try Task.checkCancellation()
                guard self.generations[token] == generation else { return }
                let state = State.loaded(response)
                self.entries[token] = Entry(minute: minute, fetchedAt: self.now(), state: state)
                self.states[token] = state
            } catch is CancellationError {
                return
            } catch {
                guard self.generations[token] == generation else { return }
                let state = Self.state(for: error)
                self.entries[token] = Entry(minute: minute, fetchedAt: self.now(), state: state)
                self.states[token] = state
            }
        }
    }

    private static func state(for error: Error) -> State {
        guard let error = error as? WeatherClientError else {
            return .unavailable(error.localizedDescription)
        }
        switch error {
        case .expired: return .expired
        case .unavailable: return .unavailable(String(localized: "Weather unavailable."))
        case .http(let code): return .unavailable(String(localized: "Weather service returned HTTP \(code)."))
        case .invalidEndpoint: return .unavailable(String(localized: "Set a supported RoadScout API base URL in Settings."))
        case .invalidResponse: return .unavailable(String(localized: "The weather service returned an unusable forecast."))
        }
    }

    private static func minuteKey(_ date: Date) -> Int { Int(floor(date.timeIntervalSince1970 / 60)) }

    deinit { for task in tasks.values { task.cancel() } }
}
