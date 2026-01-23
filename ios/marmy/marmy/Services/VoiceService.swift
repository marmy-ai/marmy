//
//  VoiceService.swift
//  marmy
//

import AVFoundation
import Speech

@Observable
final class VoiceService: NSObject {
    static let shared = VoiceService()

    // MARK: - TTS Properties

    private let synthesizer = AVSpeechSynthesizer()
    private(set) var isSpeaking = false
    var speechRate: Float = AVSpeechUtteranceDefaultSpeechRate
    var selectedVoice: AVSpeechSynthesisVoice?

    // MARK: - STT Properties

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    private(set) var isRecording = false
    private(set) var transcribedText = ""
    private(set) var authorizationStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined

    var onTranscriptionUpdate: ((String) -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    // MARK: - Available Voices

    var availableVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.starts(with: "en") }
    }

    // MARK: - TTS Methods

    func speak(_ text: String) {
        // Strip ANSI codes and clean up text for speaking
        let cleanedText = stripANSICodes(from: text)

        guard !cleanedText.isEmpty else { return }

        let utterance = AVSpeechUtterance(string: cleanedText)
        utterance.rate = speechRate
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        if let voice = selectedVoice {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }

        synthesizer.speak(utterance)
        isSpeaking = true
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    func pauseSpeaking() {
        synthesizer.pauseSpeaking(at: .word)
    }

    func continueSpeaking() {
        synthesizer.continueSpeaking()
    }

    private func stripANSICodes(from text: String) -> String {
        // Remove ANSI escape sequences
        let pattern = "\\x1B\\[[0-9;]*[a-zA-Z]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }

        let range = NSRange(text.startIndex..., in: text)
        let cleaned = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")

        // Also remove some common terminal artifacts
        return cleaned
            .replacingOccurrences(of: "", pattern: "\\[\\?.*?[hl]", with: "") // cursor commands
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - STT Methods

    func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                DispatchQueue.main.async {
                    self.authorizationStatus = status
                    continuation.resume(returning: status == .authorized)
                }
            }
        }
    }

    func requestMicrophoneAuthorization() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func startRecording() throws {
        guard authorizationStatus == .authorized else {
            throw VoiceError.notAuthorized
        }

        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            throw VoiceError.recognizerUnavailable
        }

        // Cancel any ongoing tasks
        recognitionTask?.cancel()
        recognitionTask = nil

        // Configure audio session
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()

        guard let recognitionRequest = recognitionRequest else {
            throw VoiceError.requestCreationFailed
        }

        recognitionRequest.shouldReportPartialResults = true

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            self.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        isRecording = true
        transcribedText = ""

        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }

            if let result = result {
                let text = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    self.transcribedText = text
                    self.onTranscriptionUpdate?(text)
                }
            }

            if error != nil || (result?.isFinal ?? false) {
                DispatchQueue.main.async {
                    self.stopRecording()
                }
            }
        }
    }

    func stopRecording() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)

        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil

        isRecording = false

        // Deactivate audio session
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    // MARK: - Language Selection

    var availableLanguages: [Locale] {
        SFSpeechRecognizer.supportedLocales().sorted { $0.identifier < $1.identifier }
    }

    func setLanguage(_ locale: Locale) {
        speechRecognizer = SFSpeechRecognizer(locale: locale)
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension VoiceService: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isSpeaking = false
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isSpeaking = false
        }
    }
}

// MARK: - Supporting Types

enum VoiceError: LocalizedError {
    case notAuthorized
    case recognizerUnavailable
    case requestCreationFailed
    case audioSessionFailed

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Speech recognition not authorized"
        case .recognizerUnavailable:
            return "Speech recognizer unavailable"
        case .requestCreationFailed:
            return "Failed to create recognition request"
        case .audioSessionFailed:
            return "Failed to configure audio session"
        }
    }
}

// MARK: - String Extension for Regex

private extension String {
    func replacingOccurrences(of target: String, pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return self }
        let range = NSRange(startIndex..., in: self)
        return regex.stringByReplacingMatches(in: self, range: range, withTemplate: replacement)
    }
}
