import Foundation

/// Names for agents the user has just added.
///
/// "New worker" three times over is useless in a sidebar, so each new agent gets
/// the first free number of its kind — Worker 1, Worker 2, Manager 1. Names the
/// user has typed are never touched or renumbered.
public enum DefaultAgentNaming {

    public static func prefix(for kind: AgentKind) -> String {
        switch kind {
        case .manager: return "Manager"
        case .worker: return "Worker"
        }
    }

    /// The first "<Kind> N" that no agent in this team is already called.
    ///
    /// Freed numbers are reused, because the agent that had one is gone; what
    /// matters is that the name is unique in the team right now — including
    /// against names that came from a template.
    public static func nextDisplayName(for kind: AgentKind, in topology: Topology) -> String {
        let taken = Set(topology.nodes.map { $0.displayName.trimmingCharacters(in: .whitespaces) })
        let prefix = prefix(for: kind)
        var number = 1
        while taken.contains("\(prefix) \(number)") {
            number += 1
        }
        return "\(prefix) \(number)"
    }

    /// A tmux session name that matches the display name and is free.
    ///
    /// `taken` should hold every name already claimed by a saved team and by the
    /// live server, so a new agent cannot collide with either.
    public static func sessionName(for displayName: String, avoiding taken: Set<String>) -> String {
        var allocator = SessionNameAllocator(existingNames: taken)
        let base = TmuxName.sanitize(displayName.lowercased())
        return allocator.allocate(base)
    }

    /// True for a name Marmy generated and the user has not edited. Used only to
    /// decide whether renumbering would be safe; nothing is renamed silently.
    public static func isGeneratedPlaceholder(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        for kind in AgentKind.allCases {
            let prefix = prefix(for: kind) + " "
            if trimmed.hasPrefix(prefix), Int(trimmed.dropFirst(prefix.count)) != nil {
                return true
            }
        }
        // The names Marmy used before numbering existed.
        return trimmed == "New worker" || trimmed == "New manager"
    }
}
