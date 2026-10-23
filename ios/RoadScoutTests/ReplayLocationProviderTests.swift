import Foundation
import Testing
@testable import RoadScout

@MainActor
struct ReplayLocationProviderTests {
    let sample = ReplaySample(latitude: 52, longitude: 5, speed: 10,
                              speedAccuracy: 0.5, horizontalAccuracy: 5, course: 90)

    @Test(.timeLimit(.minutes(1))) func replayEmitsSamplesAndFinishes() async {
        let provider = ReplayLocationProvider(samples: [sample, sample], interval: .milliseconds(1))
        let (stream, continuation) = AsyncStream<LocationEvent>.makeStream()
        provider.onEvent = { event in
            continuation.yield(event)
            if case .finished = event { continuation.finish() }
        }
        provider.start()
        var fixes: [LocationFix] = []
        for await event in stream {
            if case .fix(let fix) = event { fixes.append(fix) }
        }
        #expect(fixes.count == 2)
        #expect(fixes.allSatisfy { $0.speed == 10 && abs($0.timestamp.timeIntervalSinceNow) < 5 })
        provider.stop()
    }

    @Test(.timeLimit(.minutes(1))) func stopCancelsRemainingReplayEvents() async throws {
        let provider = ReplayLocationProvider(samples: [sample, sample], interval: .milliseconds(20))
        let (stream, continuation) = AsyncStream<LocationEvent>.makeStream()
        var count = 0
        provider.onEvent = { event in
            if case .fix = event {
                count += 1
                continuation.yield(event)
            }
        }
        provider.start()
        for await _ in stream { break }
        provider.stop()
        try await Task.sleep(for: .milliseconds(80))
        #expect(count == 1)
        continuation.finish()
    }
}
