import Foundation
import Testing
@testable import RoadScout

struct CameraSpeechTests {
    @Test func cameraWaitsForExistingSpeechAndExpiredWarningsAreDiscarded() {
        let now = Date(timeIntervalSince1970: 1000)
        var queue = CameraSpeechScheduler()
        let cue = CameraSpeechCue(text: "Camera ahead", language: "en-US", expiresAt: now.addingTimeInterval(8))
        #expect(queue.offer(cue, busy: true) == nil)
        #expect(queue.next(at: now.addingTimeInterval(9)) == nil)
        #expect(queue.offer(cue, busy: true) == nil)
        #expect(queue.next(at: now.addingTimeInterval(2))?.text == "Camera ahead")
        #expect(queue.next(at: now.addingTimeInterval(2)) == nil)
    }

    @Test func newCameraReplacesOldQueueAndNavigationOrMuteCanClearIt() {
        let now = Date()
        var queue = CameraSpeechScheduler()
        _ = queue.offer(CameraSpeechCue(text: "Old", language: "en", expiresAt: now.addingTimeInterval(8)), busy: true)
        _ = queue.offer(CameraSpeechCue(text: "New", language: "en", expiresAt: now.addingTimeInterval(8)), busy: true)
        #expect(queue.next(at: now)?.text == "New")
        _ = queue.offer(CameraSpeechCue(text: "Pending", language: "en", expiresAt: now.addingTimeInterval(8)), busy: true)
        queue.clear()
        #expect(queue.next(at: now) == nil)
    }
}
