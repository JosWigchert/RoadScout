import Foundation
import Testing
@testable import RoadScout

struct FoundationTests {
    @Test @MainActor func bundledReplayLoads() throws {
        _ = try ReplayLocationProvider.bundled()
    }
}
