import Foundation

@MainActor protocol SpeechScheduling {
    func enqueue(_ action: @escaping @MainActor @Sendable () -> Void)
}

/// Legacy Apple voice lookup may synchronously bridge to its own async internals.
/// Run those framework calls on the main run loop, not inside a cooperative Swift
/// task, while preserving main-actor confinement of the synthesizer and utterance.
@MainActor struct SpeechRunLoopScheduler: SpeechScheduling {
    func enqueue(_ action: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.async(execute: action)
    }
}
