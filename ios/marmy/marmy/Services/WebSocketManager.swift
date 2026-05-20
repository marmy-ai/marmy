//
//  WebSocketManager.swift
//  marmy
//

import Foundation

@Observable
final class WebSocketManager: NSObject {
    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var config: ServerConfig = .default
    private var pendingPaneId: String?

    private(set) var isConnected = false
    private(set) var lastError: Error?

    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private var reconnectTask: Task<Void, Never>?

    var onContentUpdate: ((SessionContent) -> Void)?

    override init() {
        super.init()
        self.urlSession = URLSession(
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

    /// Connect to the agent WebSocket and subscribe to the given pane.
    func connect(paneId: String?) {
        disconnect()

        guard config.isConfigured else {
            lastError = WebSocketError.notConfigured
            return
        }

        pendingPaneId = paneId

        let encodedToken = config.authToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? config.authToken
        let urlString = "\(config.webSocketURL.absoluteString)/ws?token=\(encodedToken)"
        guard let url = URL(string: urlString) else {
            lastError = WebSocketError.invalidURL
            return
        }

        webSocket = urlSession?.webSocketTask(with: url)
        webSocket?.resume()

        reconnectAttempts = 0
        lastError = nil

        receiveMessage()

        #if DEBUG
        print("🔌 WebSocket connecting to /ws")
        #endif
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        isConnected = false
        pendingPaneId = nil

        #if DEBUG
        print("🔌 WebSocket disconnected")
        #endif
    }

    // MARK: - Pane Subscription

    func subscribePaneId(_ paneId: String) {
        pendingPaneId = paneId
        guard isConnected else { return }
        sendMessage(["type": "subscribe_pane", "pane_id": paneId])
    }

    // MARK: - Message Handling

    private func receiveMessage() {
        webSocket?.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.receiveMessage()
            case .failure(let error):
                self.handleError(error)
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        let text: String
        switch message {
        case .string(let s): text = s
        case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
        @unknown default: return
        }
        parseMessage(text)
    }

    private func parseMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "pane_output":
            guard let paneId = json["pane_id"] as? String,
                  let content = json["data"] as? String else { return }
            let cursorX = json["cursor_x"] as? Int ?? -1
            let cursorY = json["cursor_y"] as? Int ?? -1
            let sessionContent = SessionContent(
                sessionId: paneId,
                content: content,
                cursorX: cursorX,
                cursorY: cursorY
            )
            DispatchQueue.main.async {
                self.onContentUpdate?(sessionContent)
            }
        default:
            break
        }
    }

    private func sendMessage(_ dict: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }
        webSocket?.send(.string(text)) { _ in }
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
        guard reconnectAttempts < maxReconnectAttempts else { return }

        reconnectAttempts += 1
        let delay = pow(2.0, Double(reconnectAttempts - 1))

        reconnectTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }

            await MainActor.run {
                #if DEBUG
                print("🔌 WebSocket reconnecting (attempt \(self.reconnectAttempts))...")
                #endif
                self.connect(paneId: self.pendingPaneId)
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
            // Subscribe to the pane now that the connection is live.
            if let paneId = self.pendingPaneId {
                self.sendMessage(["type": "subscribe_pane", "pane_id": paneId])
            }
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
            print("🔌 WebSocket closed: \(closeCode)")
            #endif
        }

        if closeCode != .goingAway {
            attemptReconnect()
        }
    }
}

// MARK: - Errors

enum WebSocketError: LocalizedError {
    case notConfigured
    case invalidURL
    case connectionFailed

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Server not configured"
        case .invalidURL: return "Invalid WebSocket URL"
        case .connectionFailed: return "WebSocket connection failed"
        }
    }
}
