import AVFoundation
import Foundation
import Speech

/// Dictation on systems without the long-form engine.
///
/// `SFSpeechRecognizer` is built for short utterances: a task stops on its own
/// after about a minute, and its partial results are one growing string that a
/// later guess can shorten. To hold a long dictation together, each task's final
/// result is committed as a stretch of speech and a fresh task is started while
/// the user is still holding. Nothing already committed is ever revisited.
///
/// If a task ends and a new one cannot be started, the words heard so far are
/// kept and the interruption is reported rather than quietly swallowed.
@MainActor
public final class LegacySpeechEngine: SpeechEngine {
    private let recognizer: SFSpeechRecognizer?
    private let capture: any MicrophoneCapturing

    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// The recording as a whole.
    private var token = 0
    /// The task within that recording, so a callback from a task that has been
    /// retired is ignored.
    private var taskToken = 0
    private var handler: (@MainActor (SpeechEvent) -> Void)?
    private var taskStarted = Date()
    private var isHolding = false

    public init(locale: Locale = Locale.current, capture: (any MicrophoneCapturing)? = nil) {
        recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
        self.capture = capture ?? AudioCapture()
    }

    public var isAvailable: Bool { recognizer?.isAvailable ?? false }
    public var supportsOnDevice: Bool { recognizer?.supportsOnDeviceRecognition ?? false }
    public var supportsLongForm: Bool { false }
    public var preparation: SpeechModelPreparation {
        isAvailable ? .ready : .unavailable("No recogniser is available for this language.")
    }

    public var authorization: SpeechAuthorization {
        SpeechAuthorization.stricter(speechAuthorization, microphoneAuthorization)
    }

    public var speechAuthorization: SpeechAuthorization {
        SpeechAuthorization(SFSpeechRecognizer.authorizationStatus())
    }

    public var microphoneAuthorization: SpeechAuthorization {
        SpeechAuthorization(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    public func requestAuthorization(_ completion: @escaping @MainActor (SpeechAuthorization) -> Void) {
        SpeechPermissions.request(currentToken: { [weak self] in self?.token ?? 0 }, completion: completion)
    }

    public func prepare() async throws {}

    /// Starts one recognition task.
    ///
    /// This recogniser is built for a single utterance and stops on its own
    /// after about a minute. Marmy does not carry on across that: audio spoken
    /// while a new task was being set up would simply be missing, and by an
    /// amount nobody can put a number on. Instead the dictation ends there, with
    /// everything heard kept in the draft and the reason on screen.
    public func start(_ handler: @escaping @MainActor (SpeechEvent) -> Void) throws {
        retire()
        token += 1
        let runToken = token
        self.handler = handler
        isHolding = true

        guard let recognizer, recognizer.isAvailable else {
            handler(.failed(.recognizerUnavailable))
            return
        }
        taskToken += 1
        let thisTask = taskToken

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        self.request = request
        taskStarted = Date()

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, runToken == self.token, thisTask == self.taskToken else { return }
                self.handle(result: result, error: error)
            }
        }

        do {
            try capture.start(
                targetFormat: nil,
                onBuffer: { buffer in
                    // Audio thread, and this closure holds this run's own
                    // request: appending here keeps every buffer in order and
                    // leaves nothing queued when the recording ends.
                    request.append(buffer)
                },
                onFailure: { [weak self] failure in
                    Task { @MainActor in
                        guard let self, runToken == self.token else { return }
                        self.handler?(.failed(.interrupted(failure.description)))
                    }
                })
            handler(.listening)
        } catch {
            isHolding = false
            handler(.failed(.audioEngine("\(error)")))
        }
    }

    public func stop() {
        isHolding = false
        // Microphone first: every buffer has been appended by the time the
        // request is told there is no more audio.
        capture.stop()
        request?.endAudio()
    }

    public func cancel() {
        retire()
        token += 1
        isHolding = false
        handler = nil
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let text = result.bestTranscription.formattedString
            let elapsed = max(Date().timeIntervalSince(taskStarted), 0.001)
            if result.isFinal {
                handler?(.finalized(text: text, start: 0, duration: elapsed))
                capture.stop()
                if isHolding {
                    // It ended while the user was still talking. Everything
                    // recognised is kept; nothing is invented about the rest.
                    isHolding = false
                    handler?(.failed(.interrupted(
                        "this Mac's recogniser handles about a minute at a time.")))
                } else {
                    handler?(.finished)
                }
                return
            }
            handler?(.volatile(text: text, start: 0, duration: elapsed))
        }
        guard let error else { return }
        let nsError = error as NSError
        let wasCancelled = nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 216
        guard !wasCancelled else { return }
        capture.stop()
        isHolding = false
        handler?(.failed(.interrupted(error.localizedDescription)))
    }

    private func retire() {
        taskToken += 1
        task?.cancel()
        request?.endAudio()
        capture.stop()
        request = nil
        task = nil
    }
}
