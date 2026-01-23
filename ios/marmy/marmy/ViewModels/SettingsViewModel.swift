//
//  SettingsViewModel.swift
//  marmy
//

import AVFoundation
import Foundation

@Observable
final class SettingsViewModel {
    // Server settings
    var host: String
    var port: String
    var authToken: String

    // Voice settings
    var ttsEnabled: Bool
    var speechRate: Float
    var selectedVoiceId: String?
    var sttLanguage: String
    var autoReadEnabled: Bool

    // State
    private(set) var isTestingConnection = false
    private(set) var connectionTestResult: ConnectionTestResult?
    private(set) var isSaving = false

    private let apiClient: APIClient
    private let keychainService: KeychainService
    private let voiceService: VoiceService
    private let defaults: UserDefaults

    init(
        apiClient: APIClient = .shared,
        keychainService: KeychainService = .shared,
        voiceService: VoiceService = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.apiClient = apiClient
        self.keychainService = keychainService
        self.voiceService = voiceService
        self.defaults = defaults

        // Load saved settings
        self.host = defaults.serverHost
        self.port = String(defaults.serverPort)
        self.authToken = keychainService.getAuthToken() ?? ""
        self.ttsEnabled = defaults.ttsEnabled
        self.speechRate = defaults.ttsSpeechRate
        self.selectedVoiceId = defaults.ttsVoiceId
        self.sttLanguage = defaults.sttLanguage
        self.autoReadEnabled = defaults.autoReadEnabled
    }

    // MARK: - Available Voices

    var availableVoices: [AVSpeechSynthesisVoice] {
        voiceService.availableVoices
    }

    var selectedVoice: AVSpeechSynthesisVoice? {
        guard let id = selectedVoiceId else { return nil }
        return availableVoices.first { $0.identifier == id }
    }

    // MARK: - Validation

    var isValid: Bool {
        !host.isBlank && !authToken.isBlank && portNumber > 0
    }

    var portNumber: Int {
        Int(port) ?? 0
    }

    // MARK: - Actions

    @MainActor
    func save() {
        isSaving = true

        // Save to UserDefaults
        defaults.serverHost = host
        defaults.serverPort = portNumber
        defaults.ttsEnabled = ttsEnabled
        defaults.ttsSpeechRate = speechRate
        defaults.ttsVoiceId = selectedVoiceId
        defaults.sttLanguage = sttLanguage
        defaults.autoReadEnabled = autoReadEnabled

        // Save auth token to Keychain
        try? keychainService.saveAuthToken(authToken)

        // Configure API client
        let config = ServerConfig(
            host: host,
            port: portNumber,
            authToken: authToken
        )
        apiClient.configure(with: config)

        // Configure voice service
        voiceService.speechRate = speechRate
        if let voice = selectedVoice {
            voiceService.selectedVoice = voice
        }
        voiceService.setLanguage(Locale(identifier: sttLanguage))

        isSaving = false
    }

    @MainActor
    func testConnection() async {
        guard isValid else {
            connectionTestResult = .failure("Invalid configuration")
            return
        }

        isTestingConnection = true
        connectionTestResult = nil

        // Temporarily configure API with current settings
        let config = ServerConfig(
            host: host,
            port: portNumber,
            authToken: authToken
        )
        apiClient.configure(with: config)

        do {
            let success = try await apiClient.healthCheck()
            connectionTestResult = success ? .success : .failure("Health check failed")
        } catch {
            connectionTestResult = .failure(error.localizedDescription)
        }

        isTestingConnection = false
    }

    func previewVoice() {
        voiceService.speechRate = speechRate
        if let voice = selectedVoice {
            voiceService.selectedVoice = voice
        }
        voiceService.speak("This is a test of the text to speech system.")
    }

    func stopPreview() {
        voiceService.stopSpeaking()
    }

    // MARK: - Load Config

    func loadSavedConfig() {
        host = defaults.serverHost
        port = String(defaults.serverPort)
        authToken = keychainService.getAuthToken() ?? ""

        if !host.isEmpty && !authToken.isEmpty {
            let config = ServerConfig(
                host: host,
                port: portNumber,
                authToken: authToken
            )
            apiClient.configure(with: config)
        }
    }

    // MARK: - App Info

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}

// MARK: - Connection Test Result

enum ConnectionTestResult: Equatable {
    case success
    case failure(String)

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var message: String {
        switch self {
        case .success:
            return "Connection successful!"
        case .failure(let error):
            return "Connection failed: \(error)"
        }
    }
}
