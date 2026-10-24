import AVFoundation

struct CameraSpeechCue: Equatable {
    let text: String
    let language: String
    let expiresAt: Date
}

struct CameraSpeechScheduler {
    private var pending: CameraSpeechCue?
    mutating func offer(_ cue: CameraSpeechCue, busy: Bool) -> CameraSpeechCue? {
        if busy { pending = cue; return nil }
        pending = nil
        return cue
    }
    mutating func next(at date: Date) -> CameraSpeechCue? {
        defer { pending = nil }
        guard let pending, pending.expiresAt > date else { return nil }
        return pending
    }
    mutating func clear() { pending = nil }
}

@MainActor protocol AudioAnnouncing: AnyObject {
    func speak(_ text: String, language: String)
    func stop()
}

@MainActor final class SpeechAnnouncer: NSObject, AudioAnnouncing, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var cameraQueue = CameraSpeechScheduler()
    private var speakingCamera = false
    private var muted = false

    override init() {
        super.init()
        synthesizer.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted),
                                                name: AVAudioSession.interruptionNotification, object: nil)
    }

    @objc nonisolated private func interrupted() { Task { @MainActor [weak self] in self?.stop() } }

    func speak(_ text: String, language: String) {
        guard !muted else { return }
        stop()
        performSpeech(text, language: language, camera: false)
    }

    func speakCamera(_ text: String, language: String) {
        guard !muted else { return }
        let cue = CameraSpeechCue(text: text, language: language, expiresAt: Date().addingTimeInterval(8))
        if let ready = cameraQueue.offer(cue, busy: synthesizer.isSpeaking) {
            performSpeech(ready.text, language: ready.language, camera: true)
        }
    }

    func setMuted(_ value: Bool) { muted = value; if value { stop() } }

    func cancelCameraWarnings() {
        cameraQueue.clear()
        if speakingCamera {
            synthesizer.stopSpeaking(at: .immediate); speakingCamera = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func performSpeech(_ text: String, language: String, camera: Bool) {
        speakingCamera = camera
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
            try session.setActive(true)
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: language)
            synthesizer.speak(utterance)
        } catch { stop() }
    }

    func stop() {
        cameraQueue.clear()
        speakingCamera = false
        synthesizer.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, !self.synthesizer.isSpeaking else { return }
            if !self.muted, let cue = self.cameraQueue.next(at: Date()) {
                self.performSpeech(cue.text, language: cue.language, camera: true)
                return
            }
            self.speakingCamera = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}
