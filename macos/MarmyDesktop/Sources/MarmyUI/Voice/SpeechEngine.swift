import AVFoundation
import Foundation
import Speech

public enum SpeechAuthorization: Equatable, Sendable {
    case authorized
    case denied
    case restricted
    case notDetermined

    /// Dictation needs the microphone *and* speech recognition, so the answer is
    /// whichever of the two says no first.
    public static func stricter(_ a: SpeechAuthorization, _ b: SpeechAuthorization) -> SpeechAuthorization {
        if a == .denied || b == .denied { return .denied }
        if a == .restricted || b == .restricted { return .restricted }
        if a == .notDetermined || b == .notDetermined { return .notDetermined }
        return .authorized
    }
}

/// Whether the on-device model this language needs is ready to use.
public enum SpeechModelPreparation: Equatable, Sendable {
    /// Still finding out what this Mac supports.
    case checking
    case ready
    /// Supported, but the model still has to be fetched or installed.
    case needsInstallation
    case installing
    case unavailable(String)

    public var isReady: Bool { self == .ready }
}

public enum SpeechFailure: Equatable, Sendable {
    case recognizerUnavailable
    case noAudioInput
    case audioEngine(String)
    case recognition(String)
    /// The recogniser stopped before the user did — a length limit, a lost
    /// model, a dropped connection. Everything heard so far is kept.
    case interrupted(String)
    /// The on-device model for this language is not installed yet.
    case modelUnavailable(String)

    public var message: String {
        switch self {
        case .recognizerUnavailable:
            return "Speech recognition is not available for this language right now."
        case .noAudioInput:
            return "No microphone input was found. Check the input device in System Settings."
        case .audioEngine(let detail):
            return "The microphone could not start: \(detail)"
        case .recognition(let detail):
            return "Dictation stopped: \(detail)"
        case .interrupted(let detail):
            return "Dictation was interrupted: \(detail) What was heard is kept in the draft."
        case .modelUnavailable(let detail):
            return "The speech model is not ready: \(detail)"
        }
    }

    /// True when the words heard so far are still good.
    public var keepsTranscript: Bool {
        switch self {
        case .interrupted: return true
        default: return false
        }
    }
}

/// What a recogniser reports.
///
/// `finalized` is audio the recogniser has committed to, anchored to where it
/// began; `volatile` is its working guess at everything since. Keeping those
/// apart is what lets a long dictation hold on to its opening sentence.
public enum SpeechEvent: Equatable, Sendable {
    /// The current guess at a stretch of audio, with the stretch it covers.
    case volatile(text: String, start: Double, duration: Double)
    case finalized(text: String, start: Double, duration: Double)
    /// The microphone is open. Until this arrives, nothing is being heard.
    case listening
    case failed(SpeechFailure)
    /// The recogniser finished of its own accord.
    case finished
    /// Something worth telling the user that does not end the dictation — the
    /// short-utterance recogniser rolling over, for instance.
    case notice(String)
}

/// Everything the voice controller needs from a speech recogniser.
///
/// The protocol exists so the whole hold-to-talk state machine can be tested
/// with scripted events, without a microphone and without asking anybody for
/// permission.
@MainActor
public protocol SpeechEngine: AnyObject {
    var isAvailable: Bool { get }
    /// True when recognition can run on this Mac without sending audio to Apple.
    var supportsOnDevice: Bool { get }
    /// True for an engine built for dictation that runs for minutes rather than
    /// a single utterance.
    var supportsLongForm: Bool { get }
    /// Whether the model is installed and ready.
    var preparation: SpeechModelPreparation { get }
    /// Fetches the model if it is supported but not installed yet.
    func prepare() async throws
    /// The stricter of the two permissions dictation needs.
    var authorization: SpeechAuthorization { get }
    /// Reported separately so a refusal can point at the right settings pane.
    var speechAuthorization: SpeechAuthorization { get }
    var microphoneAuthorization: SpeechAuthorization { get }

    func requestAuthorization(_ completion: @escaping @MainActor (SpeechAuthorization) -> Void)
    func start(_ handler: @escaping @MainActor (SpeechEvent) -> Void) throws
    /// Stop listening and let the recogniser finish the sentence.
    func stop()
    /// Stop listening and discard anything in flight.
    func cancel()
}

extension SpeechEngine {
    public var speechAuthorization: SpeechAuthorization { authorization }
    public var microphoneAuthorization: SpeechAuthorization { authorization }
    public var supportsLongForm: Bool { false }
    public var preparation: SpeechModelPreparation { .ready }
    public func prepare() async throws {}
}

extension SpeechAuthorization {
    public init(_ status: SFSpeechRecognizerAuthorizationStatus) {
        switch status {
        case .authorized: self = .authorized
        case .denied: self = .denied
        case .restricted: self = .restricted
        case .notDetermined: self = .notDetermined
        @unknown default: self = .denied
        }
    }

    public init(_ status: AVAuthorizationStatus) {
        switch status {
        case .authorized: self = .authorized
        case .denied: self = .denied
        case .restricted: self = .restricted
        case .notDetermined: self = .notDetermined
        @unknown default: self = .denied
        }
    }
}

/// Asking for the two permissions dictation needs, in order.
///
/// Both are requested only when the user actually holds to talk, and a request
/// whose token has moved on — because the hold ended, or the engine was
/// cancelled — is dropped rather than starting a recording nobody asked for.
public enum SpeechPermissions {
    @MainActor
    public static func request(
        currentToken: @escaping () -> Int,
        completion: @escaping @MainActor (SpeechAuthorization) -> Void
    ) {
        let requestToken = currentToken()
        SFSpeechRecognizer.requestAuthorization { speechStatus in
            Task { @MainActor in
                guard requestToken == currentToken() else { return }
                let speech = SpeechAuthorization(speechStatus)
                guard speech == .authorized else {
                    completion(speech)
                    return
                }
                let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
                switch microphone {
                case .authorized:
                    completion(.authorized)
                case .denied, .restricted:
                    completion(SpeechAuthorization(microphone))
                case .notDetermined:
                    AVCaptureDevice.requestAccess(for: .audio) { granted in
                        Task { @MainActor in
                            guard requestToken == currentToken() else { return }
                            completion(granted ? .authorized : .denied)
                        }
                    }
                @unknown default:
                    completion(.denied)
                }
            }
        }
    }
}
