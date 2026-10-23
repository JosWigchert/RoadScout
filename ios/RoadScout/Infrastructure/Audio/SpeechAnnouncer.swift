import AVFoundation

@MainActor protocol AudioAnnouncing: AnyObject {
    func speak(_ text: String, language: String)
    func stop()
}

@MainActor final class SpeechAnnouncer: NSObject, AudioAnnouncing, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted),
                                                name: AVAudioSession.interruptionNotification, object: nil)
    }

    @objc nonisolated private func interrupted() { Task { @MainActor [weak self] in self?.stop() } }

    func speak(_ text: String, language: String) {
        stop()
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
        synthesizer.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard self?.synthesizer.isSpeaking == false else { return }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}
