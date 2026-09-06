import AVFoundation
import Foundation
import Speech

public enum SpeechAuthorization: Equatable, Sendable {
    case authorized
    case denied
    case restricted
    case notDetermined
}

public enum SpeechFailure: Equatable, Sendable {
    case recognizerUnavailable
    case noAudioInput
    case audioEngine(String)
    case recognition(String)

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
        }
    }
}

public enum SpeechEvent: Equatable, Sendable {
    case partial(String)
    case final(String)
    case failed(SpeechFailure)
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
}

/// Apple's speech recognition driven by AVAudioEngine.
///
/// Dictation needs two separate permissions — the microphone and speech
/// recognition — and both are asked for only when the user actually holds to
/// talk. Every recognition run carries a token, so a task that is retired can
/// never tear down the audio of the one that replaced it.
@MainActor
public final class AppleSpeechEngine: SpeechEngine {
    private let recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var isTapInstalled = false
    /// Bumped by every start and every cancel, so late callbacks from a retired
    /// run are ignored instead of stopping the current one.
    private var token = 0

    public init(locale: Locale = Locale.current) {
        recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
    }

    public var isAvailable: Bool { recognizer?.isAvailable ?? false }

    public var supportsOnDevice: Bool { recognizer?.supportsOnDeviceRecognition ?? false }

    /// The stricter of the two permissions: dictation needs both.
    public var authorization: SpeechAuthorization {
        Self.combine(speechAuthorization, microphoneAuthorization)
    }

    public var speechAuthorization: SpeechAuthorization {
        Self.map(SFSpeechRecognizer.authorizationStatus())
    }

    public var microphoneAuthorization: SpeechAuthorization {
        Self.map(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    public func requestAuthorization(_ completion: @escaping @MainActor (SpeechAuthorization) -> Void) {
        // Asked only when the user holds Space or presses the microphone, never
        // at launch. Both callbacks arrive on arbitrary queues.
        let requestToken = token
        SFSpeechRecognizer.requestAuthorization { [weak self] speechStatus in
            Task { @MainActor in
                guard let self else { return }
                // A cancel while the sheet was up retires this request.
                guard requestToken == self.token else { return }
                let speech = Self.map(speechStatus)
                guard speech == .authorized else {
                    completion(speech)
                    return
                }
                self.requestMicrophone(requestToken: requestToken, completion: completion)
            }
        }
    }

    private func requestMicrophone(
        requestToken: Int,
        completion: @escaping @MainActor (SpeechAuthorization) -> Void
    ) {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            completion(.authorized)
        case .denied, .restricted:
            completion(Self.map(status))
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    guard let self, requestToken == self.token else { return }
                    completion(granted ? .authorized : .denied)
                }
            }
        @unknown default:
            completion(.denied)
        }
    }

    public func start(_ handler: @escaping @MainActor (SpeechEvent) -> Void) throws {
        // Whatever ran before is retired first, so its callbacks cannot touch
        // this run's audio.
        retireCurrentTask()
        token += 1
        let runToken = token

        guard let recognizer, recognizer.isAvailable else {
            handler(.failed(.recognizerUnavailable))
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Keeps audio on this Mac when the language pack allows it. When it does
        // not, recognition goes to Apple's servers — the composer says which.
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        self.request = request

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            cleanUp(runToken)
            handler(.failed(.noAudioInput))
            return
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        isTapInstalled = true

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            cleanUp(runToken)
            handler(.failed(.audioEngine(error.localizedDescription)))
            return
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, runToken == self.token else { return }

                if let result {
                    let text = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.cleanUp(runToken)
                        handler(.final(text))
                    } else {
                        handler(.partial(text))
                    }
                }
                // An error can arrive alongside a partial result; it still ends
                // this run and still has to be reported.
                if let error {
                    let nsError = error as NSError
                    let wasCancelled = nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 216
                    self.cleanUp(runToken)
                    if !wasCancelled {
                        handler(.failed(.recognition(error.localizedDescription)))
                    }
                }
            }
        }
    }

    public func stop() {
        request?.endAudio()
        stopAudioOnly()
    }

    public func cancel() {
        retireCurrentTask()
        token += 1
    }

    private func retireCurrentTask() {
        task?.cancel()
        request?.endAudio()
        stopAudioOnly()
        request = nil
        task = nil
    }

    private func stopAudioOnly() {
        if audioEngine.isRunning { audioEngine.stop() }
        if isTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
    }

    /// Tears down only if this is still the current run.
    private func cleanUp(_ runToken: Int) {
        guard runToken == token else { return }
        stopAudioOnly()
        request = nil
        task = nil
    }

    private static func combine(_ speech: SpeechAuthorization, _ microphone: SpeechAuthorization) -> SpeechAuthorization {
        if speech == .denied || microphone == .denied { return .denied }
        if speech == .restricted || microphone == .restricted { return .restricted }
        if speech == .notDetermined || microphone == .notDetermined { return .notDetermined }
        return .authorized
    }

    private static func map(_ status: SFSpeechRecognizerAuthorizationStatus) -> SpeechAuthorization {
        switch status {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    private static func map(_ status: AVAuthorizationStatus) -> SpeechAuthorization {
        switch status {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }
}
