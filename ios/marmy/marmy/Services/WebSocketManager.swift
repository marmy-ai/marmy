//
//  WebSocketManager.swift
//  marmy
//

import Foundation

@Observable
final class WebSocketManager: NSObject {
    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var config: ServerConfig = .default
    private var currentSessionId: String?

    private(set) var isConnected = false
    private(set) var lastError: Error?

    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private var reconnectTask: Task<Void, Never>?

    var onContentUpdate: ((SessionContent) -> Void)?

    override init() {
        super.init()
        self.session = URLSession(
            configuration: .default,
            delegate: self,
            delegateQueue: OperationQueue()
        )
    }

    // MARK: - Configuration

    func configure(with config: ServerConfig) {
        self.config = config
    }

    // MARK: - Connection Management

    func connect(sessionId: String) {
        disconnect()

        guard config.isConfigured else {
            lastError = WebSocketError.notConfigured
            return
        }

        currentSessionId = sessionId

        let urlString = "\(config.webSocketURL.absoluteString)/api/sessions/\(sessionId)/stream?token=\(config.authToken)"
        guard let url = URL(string: urlString) else {
            lastError = WebSocketError.invalidURL
            return
        }

        webSocket = session?.webSocketTask(with: url)
        webSocket?.resume()

        isConnected = true
        reconnectAttempts = 0
        lastError = nil

        receiveMessage()

        #if DEBUG
        print("🔌 WebSocket connecting to: \(sessionId)")
        #endif
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        isConnected = false
        currentSessionId = nil

        #if DEBUG
        print("🔌 WebSocket disconnected")
        #endif
    }

    // MARK: - Message Handling

    private func receiveMessage() {
        webSocket?.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.receiveMessage() // Continue listening

            case .failure(let error):
                self.handleError(error)
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            parseMessage(text)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                parseMessage(text)
            }
        @unknown default:
            break
        }
    }

    private func parseMessage(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            let wrapper = try decoder.decode(WebSocketMessage.self, from: data)

            if wrapper.type == "content" {
                DispatchQueue.main.async {
                    self.onContentUpdate?(wrapper.data)
                }
            }
        } catch {
            #if DEBUG
            print("⚠️ WebSocket parse error: \(error)")
            #endif
        }
    }

    private func handleError(_ error: Error) {
        #if DEBUG
        print("⚠️ WebSocket error: \(error)")
        #endif

        DispatchQueue.main.async {
            self.isConnected = false
            self.lastError = error
        }

        attemptReconnect()
    }

    // MARK: - Reconnection

    private func attemptReconnect() {
        guard reconnectAttempts < maxReconnectAttempts,
              let sessionId = currentSessionId else {
            return
        }

        reconnectAttempts += 1

        // Exponential backoff: 1s, 2s, 4s, 8s, 16s
        let delay = pow(2.0, Double(reconnectAttempts - 1))

        reconnectTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

            guard !Task.isCancelled else { return }

            await MainActor.run {
                #if DEBUG
                print("🔌 WebSocket reconnecting (attempt \(self.reconnectAttempts))...")
                #endif
                self.connect(sessionId: sessionId)
            }
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension WebSocketManager: URLSessionWebSocketDelegate {
    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        DispatchQueue.main.async {
            self.isConnected = true
            self.lastError = nil
            #if DEBUG
            print("🔌 WebSocket connected")
            #endif
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        DispatchQueue.main.async {
            self.isConnected = false
            #if DEBUG
            print("🔌 WebSocket closed with code: \(closeCode)")
            #endif
        }

        // Attempt reconnect if not intentionally closed
        if closeCode != .goingAway {
            attemptReconnect()
        }
    }
}

// MARK: - Supporting Types

struct WebSocketMessage: Codable {
    let type: String
    let data: SessionContent
}

enum WebSocketError: LocalizedError {
    case notConfigured
    case invalidURL
    case connectionFailed

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Server not configured"
        case .invalidURL:
            return "Invalid WebSocket URL"
        case .connectionFailed:
            return "WebSocket connection failed"
        }
    }
}
