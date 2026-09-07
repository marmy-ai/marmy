import Foundation
import Observation

/// What dictation is doing, in a form the composer can show.
public enum VoiceStatus: Equatable, Sendable {
    case idle
    case askingPermission
    /// Fetching the on-device speech model the first time it is needed.
    case preparingModel
    case starting
    case listening
    case finishing
    /// Dictation cannot run at all: permission was refused, or no recogniser.
    case unavailable(String)
    case failed(String)

    public var isCapturing: Bool {
        self == .listening || self == .starting || self == .askingPermission || self == .preparingModel
    }

    public var message: String? {
        switch self {
        case .idle: return nil
        case .askingPermission: return "Waiting for permission…"
        case .preparingModel: return "Getting the speech model ready…"
        case .starting: return "Starting…"
        case .listening: return "Listening"
        case .finishing: return "Finishing…"
        case .unavailable(let text), .failed(let text): return text
        }
    }
}

/// Hold-to-talk dictation, bound to the agent it started on.
///
/// Every capture carries a generation. Anything that should end a capture —
/// key up, switching agent, losing focus, a sheet opening, an audio failure —
/// bumps the generation, so a result that arrives late can only ever land in the
/// draft it was spoken for, and never in whatever is selected now.
@MainActor
@Observable
public final class VoiceController {
    public private(set) var status: VoiceStatus = .idle
    public private(set) var target: WorkTarget?
    /// False when recognition is going to Apple's servers rather than staying on
    /// this Mac; the composer says which.
    public private(set) var isOnDevice = false
    /// True when the engine is built for dictation that runs for minutes.
    public private(set) var isLongForm = false
    /// Whether the on-device model is ready, installing, or missing.
    public private(set) var preparation: SpeechModelPreparation = .ready
    /// Which settings pane would fix a refusal, when one is the problem.
    public private(set) var settingsPane: SettingsPane?

    public enum SettingsPane: Equatable, Sendable {
        case microphone
        case speechRecognition

        public var title: String {
            switch self {
            case .microphone: return "Open Microphone settings"
            case .speechRecognition: return "Open Speech Recognition settings"
            }
        }

        public var url: URL? {
            switch self {
            case .microphone:
                return URL(string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            case .speechRecognition:
                return URL(string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
            }
        }
    }

    @ObservationIgnored private let engine: any SpeechEngine
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var holding = false
    /// Everything heard in the current capture: committed stretches plus the
    /// working guess at the tail.
    @ObservationIgnored private var transcript = DictationTranscript()
    /// What is being heard right now, for the preview.
    public private(set) var preview: String = ""
    @ObservationIgnored private var finalizeTask: Task<Void, Never>?

    /// True when the recogniser stopped early and the words heard were kept.
    public private(set) var wasInterrupted = false
    /// The agent whose draft holds an interrupted dictation, so the composer can
    /// keep saying so.
    public private(set) var interruptedTarget: WorkTarget?
    /// Something worth knowing that did not end the dictation.
    public private(set) var notice: String?

    /// How long to wait for the recogniser's final result after the key comes
    /// up. Without a bound, a missing final would leave the composer stuck.
    public var finalizeTimeout: Duration = .seconds(3)

    /// The engine, so a harness can drive scripted speech events.
    public var engineForTesting: any SpeechEngine { engine }

    /// What should happen to the words a capture produced.
    public enum Completion: Equatable, Sendable {
        /// Put them in that agent's prompt.
        case deliver
        /// Keep them for that agent, but do not paste: the user has moved on,
        /// and typing into a terminal they are not looking at would be worse
        /// than handing the words back.
        case retain(String)
    }

    /// Called when a capture ends with words in it. The text belongs to the
    /// capture it came from — not to whatever is selected now — so the capture's
    /// own id travels with it.
    @ObservationIgnored public var onFinished: ((UUID, WorkTarget, String, Completion) -> Void)?

    /// The capture in progress, if any. Every result carries this id.
    public private(set) var captureID: UUID?

    public init(engine: any SpeechEngine) {
        self.engine = engine
    }

    public var isCapturing: Bool { status.isCapturing && target != nil }

    /// Starts dictating for one agent. Permission is asked here — on the user's
    /// hold — rather than at launch.
    public func beginHold(on target: WorkTarget) {
        guard !isCapturing else { return }
        // A capture that is finishing still has words on the way. Starting
        // another now would cancel the recogniser before they arrive.
        guard status != .finishing else { return }
        generation += 1
        let generation = generation
        holding = true
        captureID = UUID()
        transcript = DictationTranscript()
        preview = ""
        wasInterrupted = false
        notice = nil
        if interruptedTarget == target { interruptedTarget = nil }
        settingsPane = nil
        finalizeTask?.cancel()
        finalizeTask = nil
        self.target = target
        isOnDevice = engine.supportsOnDevice
        isLongForm = engine.supportsLongForm
        preparation = engine.preparation

        switch engine.authorization {
        case .authorized:
            start(generation: generation, target: target)
        case .denied:
            fail(deniedStatus(), generation: generation, target: target)
        case .restricted:
            fail(.unavailable("Speech recognition is not allowed on this Mac."),
                 generation: generation, target: target)
        case .notDetermined:
            status = .askingPermission
            engine.requestAuthorization { [weak self] authorization in
                guard let self else { return }
                // The answer can arrive after the key came back up. Permission
                // is not a reason to start recording nobody asked for any more.
                guard generation == self.generation, self.holding else {
                    self.finishQuietly(generation: generation, target: target)
                    return
                }
                switch authorization {
                case .authorized:
                    self.start(generation: generation, target: target)
                case .denied:
                    self.fail(self.deniedStatus(), generation: generation, target: target)
                case .restricted:
                    self.fail(.unavailable("Speech recognition is not allowed on this Mac."),
                              generation: generation, target: target)
                case .notDetermined:
                    self.fail(.failed("Permission was not granted."),
                              generation: generation, target: target)
                }
            }
        }
    }

    /// The key came up, or the microphone button was released.
    public func endHold() {
        holding = false
        guard let target else {
            status = .idle
            return
        }
        switch status {
        case .listening, .starting:
            status = .finishing
            // Some engines report the end synchronously inside stop(). Taking
            // the generation first means a timer is only armed if this capture
            // is genuinely still waiting.
            let capture = generation
            engine.stop()
            guard generation == capture, status == .finishing, self.target == target else { return }
            scheduleFinalization(generation: capture, target: target)
        case .askingPermission, .preparingModel:
            // Nothing was recorded, and permission or the model may still be on
            // its way: whatever arrives must not start a recording now.
            generation += 1
            engine.cancel()
            status = .idle
            self.target = nil
        case .idle, .finishing, .unavailable, .failed:
            break
        }
    }

    /// True while words are being heard for this agent.
    public func isCapturing(for target: WorkTarget) -> Bool {
        isCapturing && self.target == target
    }

    /// Finishes on our own terms if the recogniser never sends a final result.
    private func scheduleFinalization(generation: Int, target: WorkTarget) {
        finalizeTask?.cancel()
        finalizeTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.finalizeTimeout)
            guard !Task.isCancelled, generation == self.generation else { return }
            // The recogniser never came back with its last words. Whatever was
            // heard is kept, and this is not called a clean finish.
            self.engine.cancel()
            self.transcript.commitHypothesis()
            self.preview = self.transcript.text
            if self.transcript.isEmpty {
                self.retire(target: target)
                self.status = .failed("No speech was recognised.")
            } else {
                self.interrupt(
                    target: target,
                    message: "Dictation did not finish cleanly. What was heard is kept.")
            }
        }
    }

    /// Ends a capture for a reason that is not the user letting go: switching
    /// agent, losing focus, a sheet opening, the window closing.
    public func cancel(reason: String? = nil) {
        guard isCapturing || status == .finishing else { return }
        let origin = target
        let captureID = self.captureID
        transcript.commitHypothesis()
        let heard = transcript.text

        generation += 1
        holding = false
        finalizeTask?.cancel()
        finalizeTask = nil
        engine.cancel()
        target = nil
        status = reason.map { .failed($0) } ?? .idle

        // Whatever was said belongs to the agent it was said to. It is not
        // pasted — the user has looked away — but it is not thrown away either.
        if let origin, let captureID,
           !heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onFinished?(captureID, origin, heard, .retain(
                reason ?? "You moved away while dictating, so this was not put into the prompt."))
        }
        self.captureID = nil
    }

    /// Clears a message the user has read.
    public func clearStatus() {
        if case .idle = status { return }
        if isCapturing { return }
        status = .idle
    }

    // MARK: - Private

    /// Dictation needs the microphone *and* speech recognition; the message
    /// names whichever is missing and points at the pane that fixes it.
    private func deniedStatus() -> VoiceStatus {
        let microphone = engine.microphoneAuthorization
        let speech = engine.speechAuthorization
        if microphone == .denied, speech == .denied {
            settingsPane = .microphone
            return .unavailable(
                "Marmy needs both Microphone and Speech Recognition access. Turn them on in "
                    + "System Settings › Privacy & Security.")
        }
        if microphone == .denied {
            settingsPane = .microphone
            return .unavailable(
                "Marmy needs microphone access. Turn it on in "
                    + "System Settings › Privacy & Security › Microphone.")
        }
        settingsPane = .speechRecognition
        return .unavailable(
            "Marmy needs speech recognition access. Turn it on in "
                + "System Settings › Privacy & Security › Speech Recognition.")
    }

    private func start(generation: Int, target: WorkTarget) {
        preparation = engine.preparation
        if case .unavailable(let detail) = preparation {
            fail(.unavailable(detail), generation: generation, target: target)
            return
        }
        if !preparation.isReady {
            // Checking, installing, or not fetched yet — all of them mean "not
            // yet", and all of them wait rather than starting a recording that
            // would hear nothing.
            status = .preparingModel
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.engine.prepare()
                } catch {
                    guard generation == self.generation else { return }
                    self.fail(
                        .failed("The speech model could not be prepared: \(error.localizedDescription)"),
                        generation: generation, target: target)
                    return
                }
                guard generation == self.generation else { return }
                self.preparation = self.engine.preparation
                guard self.holding else {
                    // Let go while waiting: nothing starts now.
                    self.finishQuietly(generation: generation, target: target)
                    return
                }
                if case .unavailable(let detail) = self.preparation {
                    self.fail(.unavailable(detail), generation: generation, target: target)
                    return
                }
                guard self.preparation.isReady else {
                    self.fail(
                        .failed("The speech model is still not ready."),
                        generation: generation, target: target)
                    return
                }
                self.beginListening(generation: generation, target: target)
            }
            return
        }
        beginListening(generation: generation, target: target)
    }

    private func beginListening(generation: Int, target: WorkTarget) {
        // Stays "starting" until the engine says the microphone is open.
        status = .starting
        do {
            try engine.start { [weak self] event in
                self?.handle(event, generation: generation, target: target)
            }
        } catch {
            fail(.failed("The microphone could not start: \(error.localizedDescription)"),
                 generation: generation, target: target)
        }
    }

    private func handle(_ event: SpeechEvent, generation: Int, target: WorkTarget) {
        // A result from a capture that has been retired belongs to nobody: not
        // to this draft, and certainly not to whatever is selected now.
        guard generation == self.generation, self.target == target else { return }

        switch event {
        case .listening:
            // The microphone is actually open now. Until this, "starting" was
            // the truth.
            if holding { status = .listening }

        case .volatile, .finalized:
            transcript.apply(event)
            status = holding ? .listening : .finishing
            preview = transcript.text

        case .notice(let message):
            // The dictation continues; the user simply deserves to know.
            notice = message

        case .finished:
            transcript.commitHypothesis()
            preview = transcript.text
            if holding {
                // It stopped while the user was still talking. Everything heard
                // is kept, and this is not reported as a clean finish.
                interrupt(
                    target: target,
                    message: "Dictation stopped before you let go. What was heard is kept in the draft.")
            } else {
                finish(target: target)
            }

        case .failed(let failure):
            if failure.keepsTranscript {
                // Stopped early — a length limit, a lost model. The words that
                // were heard are still delivered, and the user is told why it
                // ended rather than being left to wonder.
                transcript.commitHypothesis()
                preview = transcript.text
                interrupt(target: target, message: failure.message)
                return
            }
            fail(.failed(failure.message), generation: generation, target: target)
        }
    }

    /// The capture ended before it should have. Everything heard is kept, and
    /// the UI says so rather than implying it all arrived.
    private func interrupt(target: WorkTarget, message: String) {
        engine.cancel()
        wasInterrupted = true
        interruptedTarget = target
        let heard = transcript.text
        retire(target: target)
        status = .failed(message)
        // Interrupted or not, the words were said: they still go to the agent.
        if let captureID, !heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onFinished?(captureID, target, heard, .deliver)
        }
        captureID = nil
    }

    /// Ends the capture cleanly, keeping whatever was heard.
    private func finish(target: WorkTarget) {
        // Nothing may be left holding the microphone open behind an idle UI.
        engine.cancel()
        let heard = transcript.text
        retire(target: target)
        if heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            status = .failed("No speech was recognised.")
        } else if let captureID {
            status = .idle
            onFinished?(captureID, target, heard, .deliver)
            self.captureID = nil
        } else {
            status = .idle
        }
    }

    /// Ends a capture for good: no later callback can reopen it.
    private func retire(target: WorkTarget) {
        generation += 1
        holding = false
        finalizeTask?.cancel()
        finalizeTask = nil
        self.target = nil
    }

    private func fail(_ status: VoiceStatus, generation: Int, target: WorkTarget) {
        guard generation == self.generation else { return }
        engine.cancel()
        retire(target: target)
        self.status = status
    }

    private func finishQuietly(generation: Int, target: WorkTarget) {
        guard generation == self.generation else { return }
        engine.cancel()
        retire(target: target)
        status = .idle
    }
}
