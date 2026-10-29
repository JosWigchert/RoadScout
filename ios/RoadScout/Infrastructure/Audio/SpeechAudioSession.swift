import AVFoundation

protocol SpeechAudioSessionProviding: Sendable {
    func setActive(_ active: Bool) async throws
}

struct SystemSpeechAudioSession: SpeechAudioSessionProviding {
    private static let queue = DispatchQueue(label: "RoadScout.audio-session", qos: .userInitiated)

    func setActive(_ active: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.queue.async {
                let session = AVAudioSession.sharedInstance()
                do {
                    if active {
                        try session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
                    }
                    if #available(iOS 27, *) {
                        let completion: @Sendable (Bool, Error?) -> Void = { success, error in
                            if let error { continuation.resume(throwing: error) }
                            else if success { continuation.resume() }
                            else { continuation.resume(throwing: SessionError.transitionFailed) }
                        }
                        if active { session.activate(options: [], completionHandler: completion) }
                        else { session.deactivate(options: .notifyOthersOnDeactivation, completionHandler: completion) }
                    } else {
                        // Older iOS has only the blocking API: never run it on the UI thread.
                        try session.setActive(active, options: active ? [] : .notifyOthersOnDeactivation)
                        continuation.resume()
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private enum SessionError: Error { case transitionFailed }
}

/// Audio transitions cannot overlap, even while the native asynchronous API is
/// suspended. Awaiting the previous task also orders Stop against pending activation.
@MainActor final class SpeechAudioSessionController {
    private let session: any SpeechAudioSessionProviding
    private var tail: Task<Bool, Never>?
    private var active = false

    init(session: any SpeechAudioSessionProviding = SystemSpeechAudioSession()) { self.session = session }

    @discardableResult func setActive(_ requested: Bool) -> Task<Bool, Never> {
        let previous = tail
        let task = Task { @MainActor [self] in
            _ = await previous?.value
            if active == requested { return true }
            do {
                try await session.setActive(requested)
                active = requested
                return true
            } catch { return false }
        }
        tail = task
        return task
    }
}
