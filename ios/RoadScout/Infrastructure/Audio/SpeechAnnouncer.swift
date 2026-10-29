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

@MainActor protocol SpeechSynthesizing: AnyObject {
    var isSpeaking: Bool { get }
    func speak(_ utterance: AVSpeechUtterance)
    @discardableResult func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool
}

extension AVSpeechSynthesizer: SpeechSynthesizing {}

@MainActor final class SpeechAnnouncer: NSObject, AudioAnnouncing, AVSpeechSynthesizerDelegate {
    private let synthesizer: any SpeechSynthesizing
    private var cameraQueue = CameraSpeechScheduler()
    private var speakingCamera = false
    private var muted = false
    private let audioSession: SpeechAudioSessionController
    private let speechScheduler: any SpeechScheduling
    private var speechGeneration = UUID()
    private var pendingActivation = false
    private var currentUtterance: AVSpeechUtterance?

    override init() {
        audioSession = SpeechAudioSessionController()
        speechScheduler = SpeechRunLoopScheduler()
        synthesizer = AVSpeechSynthesizer()
        super.init()
        configure()
    }

    init(audioSession: SpeechAudioSessionController, synthesizer: any SpeechSynthesizing = AVSpeechSynthesizer(),
         speechScheduler: any SpeechScheduling = SpeechRunLoopScheduler()) {
        self.audioSession = audioSession
        self.synthesizer = synthesizer
        self.speechScheduler = speechScheduler
        super.init()
        configure()
    }

    private func configure() {
        (synthesizer as? AVSpeechSynthesizer)?.delegate = self
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
        if let ready = cameraQueue.offer(cue, busy: synthesizer.isSpeaking || pendingActivation) {
            performSpeech(ready.text, language: ready.language, camera: true, expiresAt: ready.expiresAt)
        }
    }

    func setMuted(_ value: Bool) { muted = value; if value { stop() } }

    func cancelCameraWarnings() {
        cameraQueue.clear()
        if speakingCamera {
            stop()
        }
    }

    private func performSpeech(_ text: String, language: String, camera: Bool, expiresAt: Date? = nil) {
        speakingCamera = camera
        pendingActivation = true
        let generation = UUID()
        speechGeneration = generation
        let activation = audioSession.setActive(true)
        Task { @MainActor [weak self] in
            let activated = await activation.value
            guard let self, self.speechGeneration == generation, !self.muted else { return }
            self.speechScheduler.enqueue { [weak self] in
                // Stop/mute/navigation may supersede us after activation but before
                // this run-loop callback. Camera cues still count as busy until here.
                guard let self, self.speechGeneration == generation, !self.muted else { return }
                self.pendingActivation = false
                guard activated else { self.stop(); return }
                if let expiresAt, expiresAt <= Date() { self.finishedSpeech(); return }
                let utterance = AVSpeechUtterance(string: text)
                utterance.voice = AVSpeechSynthesisVoice(language: language)
                self.currentUtterance = utterance
                self.synthesizer.speak(utterance)
            }
        }
    }

    func stop() {
        cameraQueue.clear()
        speechGeneration = UUID()
        pendingActivation = false
        currentUtterance = nil
        speakingCamera = false
        synthesizer.stopSpeaking(at: .immediate)
        audioSession.setActive(false)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        complete(utterance: ObjectIdentifier(utterance))
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        complete(utterance: ObjectIdentifier(utterance))
    }

    nonisolated private func complete(utterance id: ObjectIdentifier) {
        Task { @MainActor [weak self] in
            guard let self, self.currentUtterance.map(ObjectIdentifier.init) == id,
                  !self.synthesizer.isSpeaking else { return }
            self.finishedSpeech()
        }
    }

    private func finishedSpeech() {
        currentUtterance = nil
        if !muted, let cue = cameraQueue.next(at: Date()) {
            performSpeech(cue.text, language: cue.language, camera: true, expiresAt: cue.expiresAt)
            return
        }
        speakingCamera = false
        audioSession.setActive(false)
    }

    isolated deinit {
        stop()
        NotificationCenter.default.removeObserver(self)
    }
}
