import Foundation

/// Which tmux server to talk to.
///
/// The app uses the user's default server. Tests always pass a private socket
/// name and `/dev/null` config so they cannot see, change, or inherit anything
/// from the user's real sessions.
public struct TmuxServerAddress: Sendable, Hashable, Codable {
    public var socketName: String?
    public var socketPath: String?
    public var configFile: String?

    public init(socketName: String? = nil, socketPath: String? = nil, configFile: String? = nil) {
        self.socketName = socketName
        self.socketPath = socketPath
        self.configFile = configFile
    }

    /// The user's own tmux server.
    public static let userDefault = TmuxServerAddress()

    public static func named(_ name: String, configFile: String? = nil) -> TmuxServerAddress {
        TmuxServerAddress(socketName: name, configFile: configFile)
    }

    /// Honors `MARMY_TMUX_SOCKET`, which exists so a smoke test can point the
    /// app at a scratch server instead of the user's.
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TmuxServerAddress {
        guard let value = environment["MARMY_TMUX_SOCKET"], !value.isEmpty else { return .userDefault }
        return value.contains("/")
            ? TmuxServerAddress(socketPath: value)
            : TmuxServerAddress(socketName: value)
    }

    /// Leading arguments every tmux call needs to reach this server.
    public var arguments: [String] {
        var result: [String] = []
        if let socketName { result += ["-L", socketName] }
        if let socketPath { result += ["-S", socketPath] }
        if let configFile { result += ["-f", configFile] }
        return result
    }
}

/// Enough to tell one running tmux server from a later one on the same socket.
public struct TmuxServerIdentity: Codable, Hashable, Sendable {
    public var pid: Int32
    public var socketPath: String
    public var startTime: Int

    public init(pid: Int32, socketPath: String, startTime: Int) {
        self.pid = pid
        self.socketPath = socketPath
        self.startTime = startTime
    }
}

public struct TmuxSession: Sendable, Hashable {
    /// tmux's own stable id, `$3`. Survives a rename; a new session never reuses it.
    public var id: String
    public var name: String
    public var created: Int
    public var isAttached: Bool
    public var windowCount: Int

    public init(id: String, name: String, created: Int, isAttached: Bool, windowCount: Int) {
        self.id = id
        self.name = name
        self.created = created
        self.isAttached = isAttached
        self.windowCount = windowCount
    }
}

public struct TmuxPane: Sendable, Hashable {
    public var id: String            // %4
    public var sessionID: String     // $3
    public var sessionName: String
    public var windowID: String      // @2
    public var pid: Int32
    public var currentCommand: String
    public var currentPath: String
    public var isActive: Bool
    public var isWindowActive: Bool
    /// The program in this pane has exited and tmux is keeping the pane around.
    public var isDead: Bool

    public init(
        id: String, sessionID: String, sessionName: String, windowID: String,
        pid: Int32, currentCommand: String, currentPath: String,
        isActive: Bool, isWindowActive: Bool, isDead: Bool = false
    ) {
        self.id = id
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.windowID = windowID
        self.pid = pid
        self.currentCommand = currentCommand
        self.currentPath = currentPath
        self.isActive = isActive
        self.isWindowActive = isWindowActive
        self.isDead = isDead
    }
}

/// A terminal attached to this server, and what it is currently showing.
public struct TmuxClientInfo: Sendable, Hashable {
    public var pid: Int32
    public var name: String
    public var sessionID: String
    public var sessionName: String
    /// The pane this client is currently displaying.
    public var paneID: String

    public init(pid: Int32, name: String, sessionID: String, sessionName: String, paneID: String) {
        self.pid = pid
        self.name = name
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.paneID = paneID
    }
}

/// A session plus the pane a new session starts with.
public struct TmuxStartedSession: Sendable, Hashable {
    public var sessionID: String
    public var sessionName: String
    public var paneID: String
}

public enum TmuxError: Error, CustomStringConvertible, Equatable {
    case tmuxNotInstalled(detail: String)
    case commandFailed(command: String, detail: String)
    case unexpectedOutput(command: String, output: String)
    case sessionNotFound(String)
    case paneNotFound(String)

    public var description: String {
        switch self {
        case .tmuxNotInstalled(let detail):
            return "tmux is not available: \(detail)"
        case .commandFailed(let command, let detail):
            return "tmux \(command) failed: \(detail)"
        case .unexpectedOutput(let command, let output):
            return "tmux \(command) returned something unexpected: \u{22}\(output)\u{22}"
        case .sessionNotFound(let name):
            return "tmux session \u{22}\(name)\u{22} is not running."
        case .paneNotFound(let id):
            return "tmux pane \(id) no longer exists."
        }
    }
}
