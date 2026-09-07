import Foundation
import MarmyCore
import MarmyRuntime

/// Exactly what stopping something would stop, decided when the question is
/// asked rather than when it is answered.
///
/// A confirmation has to be about what the user was looking at: the selection
/// can move, a refresh can land, an agent can exit, all while the dialog is on
/// screen. So the sessions are named here, by tmux's own id on a named server,
/// and that is what is acted on — never a name, which another session can take.
public struct SessionTerminationPlan: Equatable, Identifiable {
    /// One tmux session, and who Marmy knows is using it.
    public struct Session: Equatable, Identifiable {
        /// tmux's own id, `$3`. A new session never reuses it.
        public var id: String
        public var name: String
        public var server: TmuxServerIdentity
        /// Agents in the team being deleted that are running in it.
        public var agents: [String]
        /// Agents in *other* teams running in it. Stopping it stops them too,
        /// so it is said plainly rather than discovered afterwards.
        public var otherTeams: [String]
        /// Marmy attached to this rather than starting it.
        public var isAdopted: Bool

        public var isSharedElsewhere: Bool { !otherTeams.isEmpty }

        public init(
            id: String, name: String, server: TmuxServerIdentity,
            agents: [String] = [], otherTeams: [String] = [], isAdopted: Bool = false
        ) {
            self.id = id
            self.name = name
            self.server = server
            self.agents = agents
            self.otherTeams = otherTeams
            self.isAdopted = isAdopted
        }

        /// How this session reads in a confirmation: its name, who is in it, and
        /// anything about it the user would want to know first.
        public var summary: String {
            var pieces: [String] = []
            if !agents.isEmpty { pieces.append(agents.joined(separator: ", ")) }
            if isAdopted { pieces.append("attached, not started by Marmy") }
            if !otherTeams.isEmpty {
                pieces.append("also used by \(otherTeams.joined(separator: ", ")) in another team")
            }
            return pieces.isEmpty ? name : "\(name) — \(pieces.joined(separator: "; "))"
        }
    }

    public enum Subject: Equatable {
        /// A team being removed from Marmy, with the choice of what to do with
        /// its sessions.
        case team(Topology)
        /// One session the user asked to stop, on its own.
        case session
    }

    public var id = UUID()
    public var subject: Subject
    public var sessions: [Session]

    public init(subject: Subject, sessions: [Session]) {
        self.subject = subject
        self.sessions = sessions
    }

    public var topology: Topology? {
        if case .team(let topology) = subject { return topology }
        return nil
    }

    public var title: String {
        switch subject {
        case .team(let topology): return "Delete “\(topology.name)”?"
        case .session:
            return sessions.count == 1
                ? "Stop “\(sessions[0].name)”?"
                : "Stop \(sessions.count) sessions?"
        }
    }

    /// What the user is agreeing to, in full.
    public var message: String {
        switch subject {
        case .team:
            if sessions.isEmpty {
                return "This removes the team and its layout from Marmy. No agent in it is running "
                    + "right now, so nothing is stopped either way."
            }
            return "This removes the team and its layout from Marmy. These tmux sessions are "
                + "running:\n\(list)\n\nKeeping them leaves them running, listed under Local "
                + "sessions. Stopping them ends every window, pane and process inside them."
                + sharedWarning
        case .session:
            return "Stopping ends every window, pane and process in "
                + (sessions.count == 1 ? "it" : "them") + ":\n\(list)\n\nThis cannot be undone, and "
                + "anything running inside is not asked first." + sharedWarning
        }
    }

    private var list: String {
        sessions.map { "• \($0.summary)" }.joined(separator: "\n")
    }

    private var sharedWarning: String {
        let shared = sessions.filter(\.isSharedElsewhere)
        guard !shared.isEmpty else { return "" }
        return "\n\nAgents in other teams are running in "
            + shared.map(\.name).joined(separator: ", ")
            + ". Stopping these would stop them too."
    }
}

/// What happened when Marmy tried to stop some sessions.
public struct SessionTerminationOutcome: Equatable {
    /// Sessions that are no longer running, whether Marmy stopped them or they
    /// had already gone.
    public var stopped: [String] = []
    /// Sessions that were already gone before Marmy asked.
    public var alreadyGone: [String] = []
    /// Sessions that could not be stopped, with the reason. Nothing is claimed
    /// about these.
    public var failed: [(name: String, reason: String)] = []

    public var isCompleteSuccess: Bool { failed.isEmpty }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.stopped == rhs.stopped && lhs.alreadyGone == rhs.alreadyGone
            && lhs.failed.map(\.name) == rhs.failed.map(\.name)
    }
}
