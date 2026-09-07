import Foundation

/// Whether an agent supervises other agents or does the work.
///
/// The distinction is structural, not cosmetic: only a manager may act as a
/// reporting parent, and the two kinds get different default prompt templates.
public enum AgentKind: String, Codable, CaseIterable, Hashable, Sendable {
    case manager
    case worker

    public var displayName: String {
        switch self {
        case .manager: return "Manager"
        case .worker: return "Worker"
        }
    }
}

/// The command line agent a node is launched with.
public enum AgentCLI: String, Codable, CaseIterable, Hashable, Sendable {
    case codex
    case claude
    /// A plain interactive shell. Not an agent: a person runs things in it.
    case terminal

    public var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .terminal: return "Terminal"
        }
    }

    /// Executable looked up on `PATH` when the topology is launched. A terminal
    /// uses the user's login shell instead, resolved at launch.
    public var executableName: String {
        switch self {
        case .codex: return "codex"
        case .claude: return "claude"
        case .terminal: return ""
        }
    }

    /// True for a CLI that is an agent Marmy can talk to.
    ///
    /// A terminal is a shell. It gets no starting prompt, no role instructions,
    /// and no automatic messages: prose typed into a shell is a command, and
    /// nobody is reading it on the other end.
    public var isAutonomousAgent: Bool {
        self != .terminal
    }

    /// Whether a model can be chosen for this CLI.
    public var supportsModelChoice: Bool {
        self != .terminal
    }
}

/// One agent in a topology.
///
/// `id` is the stable identity used by every reference (parent, contacts,
/// navigation memory, templates). `sessionName` is only the tmux handle and may
/// be renamed without breaking references.
public struct AgentNode: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    /// tmux session name. Validated by `TmuxName`.
    public var sessionName: String
    /// Human label shown in the sidebar and rendered into prompts.
    public var displayName: String
    public var kind: AgentKind
    /// Free-form role title, e.g. "Swift implementation". Rendered as `{{agent.role}}`.
    public var roleTitle: String
    public var cli: AgentCLI
    /// Empty means "use whatever the CLI defaults to". We never invent model IDs.
    public var model: String
    /// Absolute working directory the CLI is started in.
    public var workingDirectory: String
    /// Reporting parent. `nil` marks a root agent.
    public var parentID: UUID?
    /// Agents this one is told it may talk to, beyond its parent and reports.
    public var contactIDs: Set<UUID>
    /// Prompt template used to render this agent's initial instructions.
    public var promptTemplateID: UUID?
    /// Extra per-agent instructions appended to the rendered prompt.
    public var notes: String
    /// Existing tmux session deliberately attached to this node, if any.
    public var attachedSessionName: String?

    public init(
        id: UUID = UUID(),
        sessionName: String,
        displayName: String? = nil,
        kind: AgentKind,
        roleTitle: String = "",
        cli: AgentCLI = .claude,
        model: String = "",
        workingDirectory: String,
        parentID: UUID? = nil,
        contactIDs: Set<UUID> = [],
        promptTemplateID: UUID? = nil,
        notes: String = "",
        attachedSessionName: String? = nil
    ) {
        self.id = id
        self.sessionName = sessionName
        self.displayName = displayName ?? sessionName
        self.kind = kind
        self.roleTitle = roleTitle
        self.cli = cli
        self.model = model
        self.workingDirectory = workingDirectory
        self.parentID = parentID
        self.contactIDs = contactIDs
        self.promptTemplateID = promptTemplateID
        self.notes = notes
        self.attachedSessionName = attachedSessionName
    }

    /// The tmux session this agent is actually reachable at.
    ///
    /// When an existing local session has been attached to this node, that
    /// session is the real address; `sessionName` is only what Marmy would
    /// create for it. Prompts and any future send-keys targeting must use this.
    public var tmuxAddress: String {
        if let attached = attachedSessionName?.trimmingCharacters(in: .whitespaces), !attached.isEmpty {
            return attached
        }
        return sessionName
    }

    /// Model string to show in UI when the field is blank.
    public var effectiveModelDescription: String {
        guard cli.supportsModelChoice else { return "shell" }
        return model.trimmingCharacters(in: .whitespaces).isEmpty ? "CLI default" : model
    }

    /// True when Marmy may send this node prose: a starting prompt, a roster
    /// update, a message you send from Marmy. False for a terminal, where text
    /// would be run as a command.
    public var acceptsAgentMessages: Bool {
        cli.isAutonomousAgent
    }
}
