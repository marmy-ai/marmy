import Foundation
import MarmyCore

/// Builds the text an agent is started with: its rendered role prompt plus the
/// tmux addresses of the people it is permitted to talk to.
///
/// This is guidance written into a prompt. It tells an agent who to talk to and
/// how to reach them; it does not and cannot enforce anything about what the
/// shell in that pane is able to do.
public enum BootstrapPrompt {

    /// Address of one peer, as the agent should use it.
    public struct Address: Sendable, Hashable {
        public var displayName: String
        public var relationship: String
        public var target: String
        /// True when the agent is running in a session the user attached rather
        /// than one Marmy created under the planned name.
        public var isExistingSession: Bool
        public var plannedName: String?
        /// True for a plain shell someone drives by hand.
        public var isManualTerminal: Bool = false
    }

    /// Renders the role prompt and appends the addressing section.
    ///
    /// `resolvedSessionNames` maps node ids to the session an agent is actually
    /// reachable at — an adopted session's real name, which can differ from the
    /// name the topology planned.
    public static func render(
        for node: AgentNode,
        in topology: Topology,
        workspace: Workspace,
        server: TmuxServerAddress = .userDefault,
        resolvedSessionNames: [UUID: String] = [:]
    ) throws -> String {
        var text = ""
        if let templateID = node.promptTemplateID, let template = workspace.promptTemplate(templateID) {
            text = try PromptRenderer.render(
                template: template,
                for: resolved(node, names: resolvedSessionNames),
                in: resolvedTopology(topology, names: resolvedSessionNames),
                operatorName: workspace.operatorName)
        }

        let addresses = addresses(for: node, in: topology, resolvedSessionNames: resolvedSessionNames)
        let section = addressingSection(
            addresses: addresses,
            own: address(of: node, names: resolvedSessionNames),
            server: server)

        if text.isEmpty { return section }
        if !text.hasSuffix("\n") { text += "\n" }
        return text + "\n" + section
    }

    /// The peers this node is permitted to contact: its manager, its direct
    /// reports, and its explicit contacts. Nobody else is listed.
    public static func addresses(
        for node: AgentNode,
        in topology: Topology,
        resolvedSessionNames: [UUID: String] = [:]
    ) -> [Address] {
        var result: [Address] = []
        var seen: Set<UUID> = [node.id]

        func append(_ peer: AgentNode, _ relationship: String) {
            guard seen.insert(peer.id).inserted else { return }
            let target = address(of: peer, names: resolvedSessionNames)
            result.append(Address(
                displayName: peer.displayName,
                relationship: relationship,
                target: target,
                isExistingSession: target != peer.sessionName,
                plannedName: target != peer.sessionName ? peer.sessionName : nil,
                isManualTerminal: !peer.acceptsAgentMessages))
        }

        if let parentID = node.parentID, let manager = topology.node(parentID) {
            append(manager, "your manager")
        }
        for report in topology.children(of: node.id) {
            append(report, "your report")
        }
        for contact in topology.contacts(of: node.id) {
            append(contact, "permitted contact")
        }
        return result
    }

    // MARK: - Text

    private static func addressingSection(
        addresses: [Address],
        own: String,
        server: TmuxServerAddress
    ) -> String {
        let tmuxPrefix = (["tmux"] + server.arguments.filter { $0 != "-f" && !$0.hasPrefix("/dev/") })
            .joined(separator: " ")

        var lines = ["Reaching other agents"]
        lines.append("You are in tmux session \(own) on this Mac.")

        if addresses.isEmpty {
            lines.append("No other agent is reachable from here. Report to your human and wait.")
        } else {
            lines.append("You may contact only these agents:")
            for address in addresses {
                var line = "- \(address.displayName) — \(address.relationship), tmux session \(address.target)"
                if address.isManualTerminal {
                    // Not an agent. Writing to it would run as a command, and
                    // nobody is waiting to read it.
                    line += " — a manual terminal a person uses; do not send it messages"
                }
                if address.isExistingSession, let planned = address.plannedName {
                    line += " (an existing session attached to this team; not \(planned))"
                }
                lines.append(line)
            }
            lines.append("")
            lines.append("To send one of them a message, type it into their pane and press Enter.")
            lines.append("send-keys takes a pane target, so a session name needs the trailing colon form:")
            lines.append("  \(tmuxPrefix) send-keys -t =<session>: -l \u{22}your message\u{22}")
            lines.append("  \(tmuxPrefix) send-keys -t =<session>: Enter")
            lines.append("Do not message any session that is not listed above.")
        }

        lines.append("")
        lines.append("After you finish an assignment, report it and wait. Do not start new work unasked.")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func address(of node: AgentNode, names: [UUID: String]) -> String {
        names[node.id] ?? node.tmuxAddress
    }

    /// A copy of the node whose `attachedSessionName` reflects where it is really
    /// running, so `{{agent.session}}` and friends render the live address.
    ///
    /// When the resolved address is the planned session name, any older
    /// attachment on the node is cleared: a session from a previous run has no
    /// business appearing in the prompts of a team being started now.
    private static func resolved(_ node: AgentNode, names: [UUID: String]) -> AgentNode {
        guard let name = names[node.id] else { return node }
        var copy = node
        copy.attachedSessionName = (name == node.sessionName) ? nil : name
        return copy
    }

    private static func resolvedTopology(_ topology: Topology, names: [UUID: String]) -> Topology {
        guard !names.isEmpty else { return topology }
        var copy = topology
        copy.nodes = topology.nodes.map { resolved($0, names: names) }
        return copy
    }
}
