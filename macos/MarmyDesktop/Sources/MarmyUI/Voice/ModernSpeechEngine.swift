import AVFoundation
import Foundation
import Speech

/// Long-form dictation with Apple's `SpeechAnalyzer`, on this Mac.
///
/// Unlike the older recogniser, this one is built to run for as long as someone
/// keeps talking: it commits stretches of speech as it goes, each anchored to the
/// audio it covers, and revises only its guess at the tail. That is what keeps
/// the first sentence of a five-minute dictation intact.
///
/// Everything is prepared before the microphone opens — the analyzer's format,
/// the converter, the results reader — so no audio is ever delivered in the
/// wrong format or dropped while something is still being worked out.
@available(macOS 26.0, *)
@MainActor
public final class ModernSpeechEngine: SpeechEngine {
    private let locale: Locale
    private let capture: any MicrophoneCapturing

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var analyzerTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var analyzerFormat: AVAudioFormat?
    /// Kept so a release during startup can still report that it ended.
    private var pendingHandler: (@MainActor (SpeechEvent) -> Void)?

    private var token = 0
    /// True once the microphone is actually open for this run.
    private var isRecording = false
    private var capabilities: Capabilities = .unknown
    private var capabilitiesTask: Task<Void, Never>?
    private var isInstalling = false

    private enum Capabilities: Equatable {
        case unknown
        case unsupported(String)
        case supported(installed: Bool)
    }

    public init(locale: Locale = Locale.current, capture: (any MicrophoneCapturing)? = nil) {
        self.locale = locale
        self.capture = capture ?? AudioCapture()
    }

    /// Reads what the system can do. Cheap, and asks for nothing.
    @discardableResult
    public func refreshCapabilities() -> Task<Void, Never> {
        capabilitiesTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            let supported = await SpeechTranscriber.supportedLocale(equivalentTo: self.locale)
            let installed = await SpeechTranscriber.installedLocales
            await MainActor.run {
                guard let match = supported else {
                    self.capabilities = .unsupported(
                        "Speech recognition does not support \(self.locale.identifier) on this Mac.")
                    return
                }
                let isInstalled = installed.contains { $0.identifier(.bcp47) == match.identifier(.bcp47) }
                self.capabilities = .supported(installed: isInstalled)
            }
        }
        capabilitiesTask = task
        return task
    }

    /// Waits for the capability check that is already running.
    public func awaitCapabilities() async {
        if capabilities == .unknown, capabilitiesTask == nil { refreshCapabilities() }
        await capabilitiesTask?.value
    }

    public var isAvailable: Bool {
        if case .supported = capabilities { return true }
        return false
    }

    public var supportsOnDevice: Bool { true }
    public var supportsLongForm: Bool { true }

    public var preparation: SpeechModelPreparation {
        switch capabilities {
        case .unknown: return .checking
        case .unsupported(let reason): return .unavailable(reason)
        case .supported(let installed):
            if isInstalling { return .installing }
            return installed ? .ready : .needsInstallation
        }
    }

    /// The long-form engine needs the microphone. It does not use the older
    /// speech-recognition service, so it does not ask for that permission.
    public var authorization: SpeechAuthorization { microphoneAuthorization }
    public var speechAuthorization: SpeechAuthorization { .authorized }

    public var microphoneAuthorization: SpeechAuthorization {
        SpeechAuthorization(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    public func requestAuthorization(_ completion: @escaping @MainActor (SpeechAuthorization) -> Void) {
        let requestToken = token
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            completion(.authorized)
        case .denied, .restricted:
            completion(SpeechAuthorization(status))
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

    /// Installs the language model if it is supported but not here yet.
    public func prepare() async throws {
        await awaitCapabilities()
        guard case .supported(let installed) = capabilities, !installed else { return }
        isInstalling = true
        defer { isInstalling = false }

        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        await refreshCapabilities().value
    }

    // MARK: - Live dictation

    public func start(_ handler: @escaping @MainActor (SpeechEvent) -> Void) throws {
        retire()
        token += 1
        let runToken = token
        pendingHandler = handler

        // Everything the microphone needs is settled first; the tap opens last.
        isRecording = false
        startupTask = Task { [weak self] in
            guard let self else { return }
            await self.awaitCapabilities()
            // The hold may have ended while capabilities were being read.
            guard !Task.isCancelled, runToken == self.token else { return }

            guard SpeechTranscriber.isAvailable, self.isAvailable else {
                handler(.failed(.recognizerUnavailable))
                return
            }
            let transcriber = SpeechTranscriber(locale: self.locale, preset: .progressiveTranscription)
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
            // …or while the analyzer's format was being negotiated. The
            // microphone must not open now.
            guard !Task.isCancelled, runToken == self.token else { return }

            self.beginRecording(
                transcriber: transcriber, format: format, runToken: runToken, handler: handler)
        }
    }

    private func beginRecording(
        transcriber: SpeechTranscriber,
        format: AVAudioFormat?,
        runToken: Int,
        handler: @escaping @MainActor (SpeechEvent) -> Void
    ) {
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.analyzerFormat = format

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    let isFinal = result.isFinal
                    let start = result.range.start.seconds
                    let duration = result.range.duration.seconds
                    await MainActor.run {
                        guard let self, runToken == self.token else { return }
                        handler(isFinal
                            ? .finalized(text: text, start: start, duration: duration)
                            : .volatile(text: text, start: start, duration: duration))
                    }
                }
                await MainActor.run {
                    guard let self, runToken == self.token else { return }
                    handler(.finished)
                }
            } catch {
                await MainActor.run {
                    guard let self, runToken == self.token else { return }
                    // Whatever was committed before this is kept.
                    handler(.failed(.interrupted(error.localizedDescription)))
                }
            }
        }

        analyzerTask = Task { [weak self] in
            do {
                try await analyzer.start(inputSequence: stream)
            } catch {
                await MainActor.run {
                    guard let self, runToken == self.token else { return }
                    handler(.failed(.interrupted(error.localizedDescription)))
                }
            }
        }

        do {
            try capture.start(
                targetFormat: format,
                onBuffer: { buffer in
                    // Audio thread: the buffer is already this app's own copy.
                    continuation.yield(AnalyzerInput(buffer: buffer))
                },
                onFailure: { [weak self] failure in
                    Task { @MainActor in
                        guard let self, runToken == self.token else { return }
                        // Keep what was heard; say the rest was lost.
                        handler(.failed(.interrupted(failure.description)))
                    }
                })
            isRecording = true
            handler(.listening)
        } catch {
            handler(.failed(.audioEngine("\(error)")))
        }
    }

    public func stop() {
        // Letting go before the microphone ever opened: there is nothing to
        // finalise, and the startup that is still running must not open it now.
        guard isRecording else {
            let handler = pendingHandler
            retire()
            token += 1
            handler?(.finished)
            return
        }
        // Microphone first, then the input stream: the last thing said is
        // already through the tap by the time the stream is closed.
        capture.stop()
        isRecording = false
        inputContinuation?.finish()
        inputContinuation = nil
        if let analyzer {
            Task { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
        }
    }

    public func cancel() {
        retire()
        token += 1
    }

    private func retire() {
        startupTask?.cancel()
        startupTask = nil
        isRecording = false
        pendingHandler = nil
        capture.stop()
        inputContinuation?.finish()
        inputContinuation = nil
        resultsTask?.cancel()
        resultsTask = nil
        analyzerTask?.cancel()
        analyzerTask = nil
        if let analyzer {
            // Cancelled, not finalised: nobody is waiting for this transcript.
            Task { try? await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil
        transcriber = nil
        analyzerFormat = nil
    }

    // MARK: - Audio from somewhere other than the microphone

    /// Runs the live path over buffers from elsewhere — a recording, in tests.
    ///
    /// Same transcriber, same format negotiation, same converter, same stream:
    /// only the source of the audio differs, so what this proves is what the
    /// microphone path does.
    public func transcribe(
        buffers: [AVAudioPCMBuffer],
        sourceFormat: AVAudioFormat
    ) async throws -> [SpeechEvent] {
        await awaitCapabilities()
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let converter = try BufferConverter(from: sourceFormat, to: format)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let collector = Task { () -> [SpeechEvent] in
            var events: [SpeechEvent] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                events.append(result.isFinal
                    ? .finalized(
                        text: text,
                        start: result.range.start.seconds,
                        duration: result.range.duration.seconds)
                    : .volatile(
                        text: text,
                        start: result.range.start.seconds,
                        duration: result.range.duration.seconds))
            }
            return events
        }

        try await analyzer.start(inputSequence: stream)
        for buffer in buffers {
            continuation.yield(AnalyzerInput(buffer: try converter.convert(buffer)))
        }
        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collector.value
    }

    /// Transcribes an audio file with the same analyzer the live path uses.
    public func transcribe(file url: URL) async throws -> [SpeechEvent] {
        let audio = try AVAudioFile(forReading: url)
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let collector = Task { () -> [SpeechEvent] in
            var events: [SpeechEvent] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                events.append(result.isFinal
                    ? .finalized(
                        text: text,
                        start: result.range.start.seconds,
                        duration: result.range.duration.seconds)
                    : .volatile(
                        text: text,
                        start: result.range.start.seconds,
                        duration: result.range.duration.seconds))
            }
            return events
        }
        try await analyzer.start(inputAudioFile: audio, finishAfterFile: true)
        return try await collector.value
    }
}
