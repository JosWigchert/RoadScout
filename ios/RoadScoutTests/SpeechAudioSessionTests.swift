import AVFoundation
import Foundation
import Testing
@testable import RoadScout

private actor SuspendedAudioSession: SpeechAudioSessionProviding {
    private(set) var requests: [Bool] = []
    private var continuation: CheckedContinuation<Void, Error>?
    func setActive(_ active: Bool) async throws {
        requests.append(active)
        if active { try await withCheckedThrowingContinuation { continuation = $0 } }
    }
    func completeActivation(success: Bool = true) {
        let pending = continuation
        continuation = nil
        if success { pending?.resume() }
        else { pending?.resume(throwing: Failure.unavailable) }
    }
    private enum Failure: Error { case unavailable }
}

@MainActor private final class RecordingSpeechOutput: SpeechSynthesizing {
    private(set) var spoken: [String] = []
    var isSpeaking = false
    func speak(_ utterance: AVSpeechUtterance) { spoken.append(utterance.speechString); isSpeaking = true }
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool { isSpeaking = false; return true }
}

@MainActor private final class ControlledSpeechScheduler: SpeechScheduling {
    var pending: [@MainActor @Sendable () -> Void] = []
    func enqueue(_ action: @escaping @MainActor @Sendable () -> Void) { pending.append(action) }
    func runPending() {
        let actions = pending
        pending.removeAll()
        for action in actions { action() }
    }
}

@MainActor private func awaitAudio(_ predicate: () async -> Bool) async {
    for _ in 0..<500 {
        if await predicate() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
    #expect(await predicate())
}

@MainActor struct SpeechAudioSessionTests {
    @Test func frameworkSpeechCallbackRunsOnMainActorOutsideSwiftTask() async {
        let scheduler = SpeechRunLoopScheduler()
        let insideTask = await withCheckedContinuation { continuation in
            scheduler.enqueue {
                MainActor.assertIsolated()
                #expect(Thread.isMainThread)
                continuation.resume(returning: withUnsafeCurrentTask { $0 != nil })
            }
        }
        #expect(!insideTask)
    }

    @Test func stopAfterActivationCancelsSpeechAlreadyQueuedOnRunLoop() async {
        let backend = SuspendedAudioSession()
        let controller = SpeechAudioSessionController(session: backend)
        let output = RecordingSpeechOutput()
        let scheduler = ControlledSpeechScheduler()
        let speech = SpeechAnnouncer(audioSession: controller, synthesizer: output, speechScheduler: scheduler)
        speech.speak("Obsolete turn", language: "en-US")
        await awaitAudio { await backend.requests == [true] }
        await backend.completeActivation()
        await awaitAudio { scheduler.pending.count == 1 }
        speech.stop()
        scheduler.runPending()
        _ = await controller.setActive(false).value
        #expect(output.spoken.isEmpty)
    }

    @Test func cameraRemainsQueuedWhileNavigationWaitsForRunLoop() async {
        let backend = SuspendedAudioSession()
        let controller = SpeechAudioSessionController(session: backend)
        let output = RecordingSpeechOutput()
        let scheduler = ControlledSpeechScheduler()
        let speech = SpeechAnnouncer(audioSession: controller, synthesizer: output, speechScheduler: scheduler)
        speech.speak("Navigation", language: "en-US")
        await awaitAudio { await backend.requests == [true] }
        await backend.completeActivation()
        await awaitAudio { scheduler.pending.count == 1 }
        speech.speakCamera("Camera", language: "en-US")
        #expect(scheduler.pending.count == 1)
        scheduler.runPending()
        #expect(output.spoken == ["Navigation"])
        speech.stop()
        _ = await controller.setActive(false).value
    }

    @Test func transitionsWaitForCompletionAndPreserveRequestOrder() async {
        let backend = SuspendedAudioSession()
        let controller = SpeechAudioSessionController(session: backend)
        let first = controller.setActive(true)
        let stopped = controller.setActive(false)
        let second = controller.setActive(true)
        await awaitAudio { await backend.requests == [true] }
        #expect(await backend.requests == [true])
        await backend.completeActivation()
        await awaitAudio { await backend.requests == [true, false, true] }
        await backend.completeActivation()
        #expect(await first.value)
        #expect(await stopped.value)
        #expect(await second.value)
        #expect(await controller.setActive(false).value)
    }

    @Test func stoppingIdleSessionDoesNotDeactivateSystemAudio() async {
        let backend = SuspendedAudioSession()
        let controller = SpeechAudioSessionController(session: backend)
        #expect(await controller.setActive(false).value)
        #expect(await controller.setActive(false).value)
        #expect(await backend.requests.isEmpty)
    }

    @Test(arguments: ["stop", "mute", "cancelCamera"])
    func cancelledPendingActivationNeverStartsSpeech(action: String) async {
        let backend = SuspendedAudioSession()
        let controller = SpeechAudioSessionController(session: backend)
        let output = RecordingSpeechOutput()
        let speech = SpeechAnnouncer(audioSession: controller, synthesizer: output)
        if action == "cancelCamera" { speech.speakCamera("Camera ahead", language: "en-US") }
        else { speech.speak("Turn right", language: "en-US") }
        await awaitAudio { await backend.requests == [true] }
        #expect(output.spoken.isEmpty)
        switch action {
        case "mute": speech.setMuted(true)
        case "cancelCamera": speech.cancelCameraWarnings()
        default: speech.stop()
        }
        await backend.completeActivation()
        await awaitAudio { await backend.requests == [true, false] }
        #expect(output.spoken.isEmpty)
    }

    @Test func activationFailureDoesNotSpeakAndNextRequestCanRetry() async {
        let backend = SuspendedAudioSession()
        let controller = SpeechAudioSessionController(session: backend)
        let output = RecordingSpeechOutput()
        let speech = SpeechAnnouncer(audioSession: controller, synthesizer: output)
        speech.speak("First", language: "en-US")
        await awaitAudio { await backend.requests == [true] }
        await backend.completeActivation(success: false)
        _ = await controller.setActive(false).value
        #expect(output.spoken.isEmpty)
        speech.speak("Retry", language: "en-US")
        await awaitAudio { await backend.requests == [true, true] }
        await backend.completeActivation()
        await awaitAudio { output.spoken == ["Retry"] }
        speech.stop()
        _ = await controller.setActive(false).value
    }

    @Test func navigationSupersedesCameraWaitingForActivation() async {
        let backend = SuspendedAudioSession()
        let controller = SpeechAudioSessionController(session: backend)
        let output = RecordingSpeechOutput()
        let speech = SpeechAnnouncer(audioSession: controller, synthesizer: output)
        speech.speakCamera("Camera", language: "en-US")
        await awaitAudio { await backend.requests == [true] }
        speech.speak("Navigation", language: "en-US")
        await backend.completeActivation()
        await awaitAudio { await backend.requests == [true, false, true] }
        await backend.completeActivation()
        await awaitAudio { output.spoken == ["Navigation"] }
        speech.stop()
        _ = await controller.setActive(false).value
    }

    @Test func cameraCannotOvertakeNavigationDuringActivation() async {
        let backend = SuspendedAudioSession()
        let controller = SpeechAudioSessionController(session: backend)
        let output = RecordingSpeechOutput()
        let speech = SpeechAnnouncer(audioSession: controller, synthesizer: output)
        speech.speak("Navigation", language: "en-US")
        speech.speakCamera("Camera", language: "en-US")
        await awaitAudio { await backend.requests == [true] }
        await backend.completeActivation()
        await awaitAudio { output.spoken == ["Navigation"] }
        speech.stop()
        _ = await controller.setActive(false).value
        #expect(output.spoken == ["Navigation"])
    }
}
