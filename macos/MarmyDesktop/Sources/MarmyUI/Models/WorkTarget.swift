import Foundation
import MarmyCore
import MarmyRuntime

/// What the work view is pointed at.
///
/// A node belongs to a saved team. A local session is one the user opened
/// directly from the sidebar: it gets a terminal, a draft, and dictation, but it
/// is not part of any team and never receives bootstrap instructions.
public enum WorkTarget: Hashable, Sendable, Identifiable {
    case node(UUID)
    case localSession(LocalSessionKey)

    public var id: String {
        switch self {
        case .node(let nodeID): return "node:\(nodeID.uuidString)"
        case .localSession(let key): return key.id
        }
    }

    public var nodeID: UUID? {
        if case .node(let id) = self { return id }
        return nil
    }

    public var localSession: LocalSessionKey? {
        if case .localSession(let key) = self { return key }
        return nil
    }
}

/// Identity of a session opened directly from the sidebar.
///
/// tmux hands out session ids per server, so `$0` on a restarted server is a
/// different session entirely. The server it belongs to is part of the key, so a
/// new session can never inherit an old one's draft or a late transcript.
public struct LocalSessionKey: Hashable, Sendable {
    public var sessionID: String
    public var server: TmuxServerIdentity
    /// The pane that was on screen when the session was opened. Delivery checks
    /// it is still the visible one.
    public var paneID: String

    public init(sessionID: String, server: TmuxServerIdentity, paneID: String) {
        self.sessionID = sessionID
        self.server = server
        self.paneID = paneID
    }

    public var id: String {
        "session:\(server.socketPath):\(server.pid):\(server.startTime):\(sessionID):\(paneID)"
    }

    /// True when this key still refers to something on the server in front of us.
    public func matches(_ current: TmuxServerIdentity?) -> Bool {
        current == server
    }
}

/// The centre of the window.
public enum WorkMode: String, CaseIterable, Sendable {
    case work
    case topology

    public var title: String {
        switch self {
        case .work: return "Work"
        case .topology: return "Topology"
        }
    }
}

/// A short message shown under the toolbar.
public struct Banner: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable {
        case info
        case success
        case warning
        case failure
    }

    public let id = UUID()
    public var kind: Kind
    public var title: String
    public var detail: String?

    public init(kind: Kind, title: String, detail: String? = nil) {
        self.kind = kind
        self.title = title
        self.detail = detail
    }

    public static func failure(_ title: String, _ detail: String? = nil) -> Banner {
        Banner(kind: .failure, title: title, detail: detail)
    }

    public static func success(_ title: String, _ detail: String? = nil) -> Banner {
        Banner(kind: .success, title: title, detail: detail)
    }
}

/// Connection state of the target the work view is showing, in plain words.
///
/// "Ready" is never claimed: Marmy knows a pane is alive, not that the agent
/// inside it has finished starting.
public enum TargetConnection: Equatable, Sendable {
    case notStarted
    case starting
    case attached(sessionName: String, paneID: String, adopted: Bool)
    case ended(reason: String)
    case failed(reason: String)

    public var label: String {
        switch self {
        case .notStarted: return "Not started"
        case .starting: return "Starting…"
        case .attached(let sessionName, _, let adopted):
            return adopted ? "Attached to \(sessionName)" : "Session \(sessionName) running"
        case .ended: return "Session ended"
        case .failed: return "Start failed"
        }
    }

    public var detail: String? {
        switch self {
        case .ended(let reason), .failed(let reason): return reason
        default: return nil
        }
    }

    public var isLive: Bool {
        if case .attached = self { return true }
        return false
    }
}

extension AgentRuntimeState {
    var connection: TargetConnection {
        switch self {
        case .notLaunched: return .notStarted
        case .launching: return .starting
        case .running(let paneID, let sessionName, let adopted):
            return .attached(sessionName: sessionName, paneID: paneID, adopted: adopted)
        case .missing(let reason): return .ended(reason: reason)
        case .failed(let reason): return .failed(reason: reason)
        }
    }
}
