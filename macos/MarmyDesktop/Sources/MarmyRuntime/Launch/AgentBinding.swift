import Foundation
import MarmyCore

/// How Marmy came to be attached to a session.
public enum SessionOwnership: String, Codable, Sendable {
    /// Marmy started this session.
    case launched
    /// The user explicitly attached an existing session to a node.
    case adopted
}

/// The link between a node in a saved team and a live tmux pane.
///
/// Names are not identity: the tmux session id, pane id, and the identity of the
/// server they live on are all recorded, so a same-name session created later is
/// recognised as a different thing rather than silently typed into.
public struct AgentBinding: Codable, Hashable, Sendable {
    public var topologyID: UUID
    public var nodeID: UUID
    /// New for every start attempt, so a retry can never be confused with the
    /// run it replaced.
    public var generation: UUID
    public var sessionName: String
    public var sessionID: String
    public var paneID: String
    public var server: TmuxServerIdentity
    public var ownership: SessionOwnership
    /// Which CLI the user said this is. Recorded on adoption because a pane's
    /// current command does not reliably identify the agent running in it.
    public var cli: AgentCLI?
    /// What tmux called the program in this pane just after it started.
    ///
    /// It is not always the CLI's own name — Claude reports its version — so it
    /// is recorded rather than assumed, and later compared for change.
    public var launchCommand: String?
    public var startedAt: Date

    public init(
        topologyID: UUID,
        nodeID: UUID,
        generation: UUID,
        sessionName: String,
        sessionID: String,
        paneID: String,
        server: TmuxServerIdentity,
        ownership: SessionOwnership,
        cli: AgentCLI?,
        launchCommand: String? = nil,
        startedAt: Date
    ) {
        self.topologyID = topologyID
        self.nodeID = nodeID
        self.generation = generation
        self.sessionName = sessionName
        self.sessionID = sessionID
        self.paneID = paneID
        self.server = server
        self.ownership = ownership
        self.cli = cli
        self.launchCommand = launchCommand
        self.startedAt = startedAt
    }

    /// Value written to the session's `@marmy_agent` option for sessions Marmy
    /// started, so ownership survives even if the ledger is lost.
    public var ownershipMarker: String {
        "\(topologyID.uuidString):\(nodeID.uuidString):\(generation.uuidString)"
    }

    public static let ownershipOptionName = "@marmy_agent"
}

/// What Marmy currently knows about one node.
public enum AgentRuntimeState: Equatable, Sendable {
    /// No binding: nothing was ever started for this node.
    case notLaunched
    /// A start is in flight.
    case launching
    /// Bound to a live pane. `adopted` distinguishes an attached session from
    /// one Marmy started.
    case running(paneID: String, sessionName: String, adopted: Bool)
    /// There is a binding, but the pane it names is gone or belongs to something
    /// else now. The user reconnects or starts fresh; Marmy never guesses.
    case missing(reason: String)
    /// The last start attempt failed.
    case failed(reason: String)

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    /// Whether a launch should start this node. A pane that is alive is never
    /// restarted, and a missing one is only restarted deliberately.
    public var needsStart: Bool {
        switch self {
        case .notLaunched, .failed, .missing: return true
        case .launching, .running: return false
        }
    }
}

/// Everything Marmy knows about a team's live state at one moment.
public struct RuntimeSnapshot: Sendable {
    public var states: [UUID: AgentRuntimeState]
    public var sessions: [TmuxSession]
    public var panes: [TmuxPane]
    public var server: TmuxServerIdentity?

    public init(
        states: [UUID: AgentRuntimeState],
        sessions: [TmuxSession],
        panes: [TmuxPane],
        server: TmuxServerIdentity?
    ) {
        self.states = states
        self.sessions = sessions
        self.panes = panes
        self.server = server
    }

    public func state(of nodeID: UUID) -> AgentRuntimeState {
        states[nodeID] ?? .notLaunched
    }

    /// Live sessions that are not bound to any node — what the sidebar offers
    /// under "existing sessions".
    public func unassignedSessions(boundSessionIDs: Set<String>) -> [TmuxSession] {
        sessions.filter { !boundSessionIDs.contains($0.id) }
    }
}
