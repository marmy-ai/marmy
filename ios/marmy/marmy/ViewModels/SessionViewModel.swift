//
//  SessionViewModel.swift
//  marmy
//

import Foundation

@Observable
final class SessionViewModel {
    let project: Project

    private(set) var sessionContent: String = ""
    private(set) var isLoading = false
    private(set) var isSubmitting = false
    private(set) var error: Error?
    private(set) var lastUpdated: Date?

    var inputText = ""

    private let apiClient: APIClient
    private let webSocketManager: WebSocketManager
    private let voiceService: VoiceService

    private var pollingTask: Task<Void, Never>?
    private var useWebSocket = true

    init(
        project: Project,
        apiClient: APIClient = .shared,
        webSocketManager: WebSocketManager = WebSocketManager(),
        voiceService: VoiceService = .shared
    ) {
        self.project = project
        self.apiClient = apiClient
        self.webSocketManager = webSocketManager
        self.voiceService = voiceService

        setupWebSocket()
    }

    deinit {
        disconnect()
    }

    var sessionId: String {
        project.sessionId ?? project.name
    }

    var hasSession: Bool {
        project.hasSession
    }

    var hasError: Bool {
        error != nil
    }

    var canSubmit: Bool {
        !inputText.isBlank && !isSubmitting
    }

    var isConnected: Bool {
        webSocketManager.isConnected
    }

    // MARK: - Setup

    private func setupWebSocket() {
        webSocketManager.configure(with: apiClient.getConfig())

        webSocketManager.onContentUpdate = { [weak self] content in
            guard let self = self else { return }
            self.sessionContent = content.content
            self.lastUpdated = content.timestamp

            // Auto-read if enabled
            if UserDefaults.standard.autoReadEnabled {
                self.readContent()
            }
        }
    }

    // MARK: - Connection

    @MainActor
    func connect() async {
        isLoading = true
        error = nil

        // First, fetch initial content
        await loadContent()

        // Then try WebSocket
        if useWebSocket {
            webSocketManager.connect(sessionId: sessionId)
        } else {
            startPolling()
        }

        isLoading = false
    }

    func disconnect() {
        pollingTask?.cancel()
        pollingTask = nil
        webSocketManager.disconnect()
        voiceService.stopSpeaking()
    }

    // MARK: - Content Loading

    @MainActor
    func loadContent() async {
        do {
            let content = try await apiClient.getSessionContent(id: sessionId)
            sessionContent = content.content
            lastUpdated = content.timestamp
            error = nil
        } catch let apiError as APIError {
            if case .notFound = apiError {
                // Session doesn't exist yet, that's OK
                sessionContent = ""
            } else {
                error = apiError
            }
        } catch {
            self.error = error
        }
    }

    @MainActor
    func refresh() async {
        await loadContent()
    }

    // MARK: - Polling Fallback

    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

                guard !Task.isCancelled else { break }

                await self?.loadContent()
            }
        }
    }

    // MARK: - Input Submission

    @MainActor
    func submit() async {
        guard canSubmit else { return }

        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        inputText = ""

        isSubmitting = true
        error = nil

        do {
            try await apiClient.submitToSession(id: sessionId, text: text)

            // Reload content after submission
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 second delay
            await loadContent()
        } catch {
            self.error = error
        }

        isSubmitting = false
    }

    @MainActor
    func submitText(_ text: String) async {
        inputText = text
        await submit()
    }

    // MARK: - Session Management

    @MainActor
    func killSession() async throws {
        try await apiClient.deleteSession(id: sessionId)
        sessionContent = ""
    }

    // MARK: - Voice

    func readContent() {
        voiceService.speak(sessionContent)
    }

    func stopReading() {
        voiceService.stopSpeaking()
    }

    var isSpeaking: Bool {
        voiceService.isSpeaking
    }

    // MARK: - Voice Input

    func startVoiceInput() throws {
        try voiceService.startRecording()
        voiceService.onTranscriptionUpdate = { [weak self] text in
            self?.inputText = text
        }
    }

    func stopVoiceInput() {
        voiceService.stopRecording()
    }

    var isRecording: Bool {
        voiceService.isRecording
    }

    // MARK: - WebSocket/Polling Toggle

    func setUseWebSocket(_ enabled: Bool) {
        useWebSocket = enabled

        if enabled {
            pollingTask?.cancel()
            webSocketManager.connect(sessionId: sessionId)
        } else {
            webSocketManager.disconnect()
            startPolling()
        }
    }
}
