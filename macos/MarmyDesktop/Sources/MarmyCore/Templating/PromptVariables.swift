import Foundation

/// Builds the render context for one agent: its own identity, its manager, the
/// agents reporting to it, and the peers it is permitted to talk to.
///
/// Every list is derived in topology order, so the same topology always renders
/// the same prompt text.
public enum PromptVariables {

    /// Variable names templates may use. The editor offers these, and the
    /// validator rejects anything else as a malformed variable.
    public static let allKeys: [String] = [
        "topology.name",
        "agent.name",
        "agent.session",
        "agent.kind",
        "agent.role",
        "agent.cli",
        "agent.model",
        "agent.cwd",
        "agent.notes",
        "manager.name",
        "manager.session",
        "manager.role",
        "reports",
        "reports.list",
        "contacts",
        "contacts.list",
        "human.name",
    ]

    public static let allKeySet: Set<String> = Set(allKeys)

    /// Human-readable descriptions for the template editor's variable palette.
    public static let keyDescriptions: [String: String] = [
        "topology.name": "Name of the team this agent belongs to",
        "agent.name": "This agent's display name",
        "agent.session": "The tmux session this agent is reachable at",
        "agent.kind": "Manager or Worker",
        "agent.role": "Free-form role title",
        "agent.cli": "Codex or Claude Code",
        "agent.model": "Model override, empty when the CLI default is used",
        "agent.cwd": "Working directory the CLI starts in",
        "agent.notes": "Per-agent extra instructions",
        "manager.name": "Reporting parent's display name, empty for a root agent",
        "manager.session": "Reporting parent's tmux session name",
        "manager.role": "Reporting parent's role title",
        "reports": "Direct reports, comma separated",
        "reports.list": "Direct reports, one bulleted line each",
        "contacts": "Permitted contacts, comma separated",
        "contacts.list": "Permitted contacts, one bulleted line each",
        "human.name": "What agents should call the human who owns this Mac",
    ]

    /// `operatorName` is the human this team answers to. Blank renders as
    /// "your human" so a prompt never contains an empty name.
    public static func context(
        for node: AgentNode,
        in topology: Topology,
        operatorName: String = ""
    ) -> PromptRenderContext {
        let manager = node.parentID.flatMap { topology.node($0) }
        let reports = topology.children(of: node.id)
        let contacts = topology.contacts(of: node.id)

        var values: [String: String] = [
            "topology.name": topology.name,
            "agent.name": node.displayName,
            "agent.session": node.tmuxAddress,
            "agent.kind": node.kind.displayName,
            "agent.role": node.roleTitle,
            "agent.cli": node.cli.displayName,
            "agent.model": node.model.trimmingCharacters(in: .whitespaces),
            "agent.cwd": node.workingDirectory,
            "agent.notes": node.notes,
            "manager.name": manager?.displayName ?? "",
            "manager.session": manager?.tmuxAddress ?? "",
            "manager.role": manager?.roleTitle ?? "",
            "reports": joined(reports),
            "reports.list": bulleted(reports),
            "contacts": joined(contacts),
            "contacts.list": bulleted(contacts),
            "human.name": humanName(operatorName),
        ]

        // Guarantee every documented key exists so a template can never fail to
        // render for a reason the user cannot see.
        for key in allKeys where values[key] == nil {
            values[key] = ""
        }
        return PromptRenderContext(values)
    }

    private static func humanName(_ operatorName: String) -> String {
        let trimmed = operatorName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "your human" : trimmed
    }

    private static func joined(_ nodes: [AgentNode]) -> String {
        nodes.map { "\($0.displayName) (\($0.tmuxAddress))" }.joined(separator: ", ")
    }

    private static func bulleted(_ nodes: [AgentNode]) -> String {
        nodes.map { "- \($0.displayName) — \($0.kind.displayName), tmux session \($0.tmuxAddress)" }
            .joined(separator: "\n")
    }
}

/// Renders an agent's initial prompt from its assigned template.
public enum PromptRenderer {

    /// Renders `template` for `node`, appending the agent's own notes when the
    /// template does not already place them.
    public static func render(
        template: PromptTemplate,
        for node: AgentNode,
        in topology: Topology,
        operatorName: String = ""
    ) throws -> String {
        let context = PromptVariables.context(for: node, in: topology, operatorName: operatorName)
        var text = try PromptTemplateSyntax.render(template.body, context: context)

        let notes = node.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let usesNotes = (try? PromptTemplateSyntax.referencedVariables(in: template.body))?
            .contains("agent.notes") ?? false
        if !notes.isEmpty && !usesNotes {
            if !text.hasSuffix("\n") { text += "\n" }
            text += "\n" + notes + "\n"
        }
        return text
    }

    /// Renders every node in a topology, in topology order. Nodes without a
    /// template are skipped; the validator warns about them separately.
    public static func renderAll(
        in topology: Topology,
        templates: [PromptTemplate],
        operatorName: String = ""
    ) throws -> [(node: AgentNode, prompt: String)] {
        var results: [(AgentNode, String)] = []
        for node in topology.nodes {
            guard let templateID = node.promptTemplateID,
                  let template = templates.first(where: { $0.id == templateID })
            else { continue }
            results.append((node, try render(
                template: template, for: node, in: topology, operatorName: operatorName)))
        }
        return results
    }
}
