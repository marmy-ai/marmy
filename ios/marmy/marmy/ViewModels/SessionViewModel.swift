//
//  SessionViewModel.swift
//  marmy
//

import Foundation

@Observable
final class SessionViewModel {
    let project: Project

    private(set) var sessionContent: String = ""
    private(set) var cursorX: Int = -1
    private(set) var cursorY: Int = -1
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
    private var activePaneId: String?
    private(set) var paneHeight: Int = 50

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
            self.cursorX = content.cursorX
            self.cursorY = content.cursorY
            self.lastUpdated = content.timestamp

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

        // Resolve the active pane for this session, then start WS.
        await resolveActivePaneAndConnect()

        isLoading = false
    }

    @MainActor
    private func resolveActivePaneAndConnect() async {
        do {
            let topology = try await apiClient.getTopology()
            if let session = topology.sessions.first(where: { $0.name == sessionId }) {
                let pane = topology.panes.filter { $0.sessionId == session.id }.first(where: { $0.active })
                       ?? topology.panes.first(where: { $0.sessionId == session.id })
                activePaneId = pane?.id
                paneHeight = pane?.height ?? 50
                // Seed content from topology's pane (if available) so something shows immediately.
                if sessionContent.isEmpty, let paneId = activePaneId {
                    if let content = try? await apiClient.getPaneContent(paneId: paneId) {
                        sessionContent = content
                    }
                }
            }
        } catch {
            // Non-fatal — WS will connect without pane subscription.
        }

        if useWebSocket {
            webSocketManager.connect(paneId: activePaneId)
        } else {
            startPolling()
        }
    }

    func disconnect() {
        pollingTask?.cancel()
        pollingTask = nil
        webSocketManager.disconnect()
        voiceService.stopSpeaking()
    }

    // MARK: - Content Loading

    @MainActor
    func refresh() async {
        guard let paneId = activePaneId else { return }
        if let content = try? await apiClient.getPaneContent(paneId: paneId) {
            sessionContent = content
        }
    }

    // MARK: - Polling Fallback

    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { break }
                await self?.refresh()
            }
        }
    }

    // MARK: - Input Submission

    @MainActor
    func submit() async {
        guard canSubmit, let paneId = activePaneId else { return }

        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        inputText = ""

        isSubmitting = true
        error = nil

        do {
            try await apiClient.sendInput(paneId: paneId, keys: text + "\n")
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

    // MARK: - File Upload

    @MainActor
    func uploadImage(data: Data, fileExtension: String) async {
        do {
            _ = try await apiClient.uploadFile(imageData: data, fileExtension: fileExtension, sessionName: sessionId)
        } catch {
            self.error = error
        }
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
            webSocketManager.connect(paneId: activePaneId)
        } else {
            webSocketManager.disconnect()
            startPolling()
        }
    }
}
