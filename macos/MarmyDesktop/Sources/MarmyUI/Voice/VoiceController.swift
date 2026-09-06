import Foundation
import Observation

/// What dictation is doing, in a form the composer can show.
public enum VoiceStatus: Equatable, Sendable {
    case idle
    case askingPermission
    case starting
    case listening
    case finishing
    /// Dictation cannot run at all: permission was refused, or no recogniser.
    case unavailable(String)
    case failed(String)

    public var isCapturing: Bool {
        self == .listening || self == .starting || self == .askingPermission
    }

    public var message: String? {
        switch self {
        case .idle: return nil
        case .askingPermission: return "Waiting for permission…"
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
    @ObservationIgnored private let drafts: DraftStore
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var holding = false
    @ObservationIgnored private var latestPartial = ""
    @ObservationIgnored private var finalizeTask: Task<Void, Never>?

    /// How long to wait for the recogniser's final result after the key comes
    /// up. Without a bound, a missing final would leave the composer stuck.
    public var finalizeTimeout: Duration = .seconds(3)

    /// The engine, so a harness can drive scripted speech events.
    public var engineForTesting: any SpeechEngine { engine }

    public init(engine: any SpeechEngine, drafts: DraftStore) {
        self.engine = engine
        self.drafts = drafts
    }

    public var isCapturing: Bool { status.isCapturing && target != nil }

    /// Starts dictating for one agent. Permission is asked here — on the user's
    /// hold — rather than at launch.
    public func beginHold(on target: WorkTarget) {
        guard !isCapturing else { return }
        generation += 1
        let generation = generation
        holding = true
        latestPartial = ""
        settingsPane = nil
        finalizeTask?.cancel()
        finalizeTask = nil
        self.target = target
        isOnDevice = engine.supportsOnDevice
        drafts.beginDictation(on: target)

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
            engine.stop()
            scheduleFinalization(generation: generation, target: target)
        case .askingPermission:
            // Nothing was recorded and permission may still be pending: the
            // answer, whenever it comes, must not start a recording now.
            generation += 1
            engine.cancel()
            status = .idle
            drafts.endDictation(on: target)
            self.target = nil
        case .idle, .finishing, .unavailable, .failed:
            break
        }
    }

    /// Finishes on our own terms if the recogniser never sends a final result.
    private func scheduleFinalization(generation: Int, target: WorkTarget) {
        finalizeTask?.cancel()
        finalizeTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.finalizeTimeout)
            guard !Task.isCancelled, generation == self.generation else { return }
            self.engine.cancel()
            self.retire(target: target)
            // Whatever was heard by then is already in the draft.
            self.status = self.latestPartial.isEmpty
                ? .failed("No speech was recognised.")
                : .idle
        }
    }

    /// Ends a capture for a reason that is not the user letting go: switching
    /// agent, losing focus, a sheet opening, the window closing.
    public func cancel(reason: String? = nil) {
        guard isCapturing || status == .finishing else { return }
        generation += 1
        holding = false
        finalizeTask?.cancel()
        finalizeTask = nil
        engine.cancel()
        if let target { drafts.endDictation(on: target) }
        target = nil
        status = reason.map { .failed($0) } ?? .idle
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
        status = .starting
        do {
            try engine.start { [weak self] event in
                self?.handle(event, generation: generation, target: target)
            }
            if status == .starting { status = .listening }
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
        case .partial(let text):
            latestPartial = text
            status = holding ? .listening : .finishing
            drafts.applyDictation(text, to: target)
        case .final(let text):
            // A blank final result must not wipe out what was already heard.
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolved = trimmed.isEmpty ? latestPartial : text
            if !trimmed.isEmpty { latestPartial = text }
            drafts.applyDictation(resolved, to: target)
            retire(target: target)
            status = resolved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .failed("No speech was recognised.")
                : .idle
        case .failed(let failure):
            fail(.failed(failure.message), generation: generation, target: target)
        }
    }

    /// Ends a capture for good: no later callback can reopen it.
    private func retire(target: WorkTarget) {
        generation += 1
        holding = false
        finalizeTask?.cancel()
        finalizeTask = nil
        drafts.endDictation(on: target)
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
