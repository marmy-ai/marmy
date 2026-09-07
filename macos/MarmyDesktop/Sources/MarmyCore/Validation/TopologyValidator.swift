import Foundation

/// Checks a topology is coherent before anyone tries to launch it.
///
/// The validator is pure: it never touches the filesystem, tmux, or the network.
/// Filesystem and CLI-availability preflight belongs to the launch phase.
public enum TopologyValidator {

    /// All problems with `topology`, errors first, then in topology order.
    public static func validate(
        _ topology: Topology,
        promptTemplates: [PromptTemplate] = []
    ) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []

        if topology.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(ValidationIssue(
                kind: .emptyTopologyName,
                severity: .error,
                message: "This team needs a name."))
        }

        if topology.nodes.isEmpty {
            issues.append(ValidationIssue(
                kind: .noNodes,
                severity: .warning,
                message: "This team has no agents yet."))
            return issues
        }

        issues += duplicateIDIssues(topology)
        issues += nodeIssues(topology, promptTemplates: promptTemplates)
        issues += sessionNameIssues(topology)
        issues += reportingIssues(topology)
        issues += templateIssues(topology, promptTemplates: promptTemplates)

        if topology.nodes.count > 1 && !topology.nodes.contains(where: { $0.kind == .manager }) {
            issues.append(ValidationIssue(
                kind: .noManager,
                severity: .warning,
                message: "No agent in this team is a manager, so nobody can take reports."))
        }

        return issues.sorted { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            return orderIndex(lhs, in: topology) < orderIndex(rhs, in: topology)
        }
    }

    /// Checks a prompt template on its own, for the template editor.
    public static func validate(template: PromptTemplate) -> [ValidationIssue] {
        do {
            try PromptTemplateSyntax.validate(template.body, knownVariables: PromptVariables.allKeySet)
            return []
        } catch let error as PromptTemplateError {
            return [issue(for: error, templateID: template.id)]
        } catch {
            return [ValidationIssue(
                kind: .malformedPromptTemplate(templateID: template.id, detail: "\(error)"),
                severity: .error,
                message: "\u{22}\(template.name)\u{22} could not be parsed: \(error)")]
        }
    }

    // MARK: - Pieces

    private static func duplicateIDIssues(_ topology: Topology) -> [ValidationIssue] {
        var seen: Set<UUID> = []
        var duplicates: [UUID] = []
        for node in topology.nodes where !seen.insert(node.id).inserted {
            if !duplicates.contains(node.id) { duplicates.append(node.id) }
        }
        return duplicates.map { id in
            ValidationIssue(
                kind: .duplicateNodeID(id),
                severity: .error,
                message: "Two agents share the same identity. Recreate one of them.",
                nodeID: id)
        }
    }

    private static func nodeIssues(
        _ topology: Topology,
        promptTemplates: [PromptTemplate]
    ) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        for node in topology.nodes {
            let label = displayLabel(node)

            if let problem = TmuxName.problem(with: node.sessionName) {
                issues.append(ValidationIssue(
                    kind: .invalidSessionName(nodeID: node.id, name: node.sessionName, problem: problem),
                    severity: .error,
                    message: "\(label): \(problem.message)",
                    nodeID: node.id))
            }

            if node.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(ValidationIssue(
                    kind: .emptyDisplayName(nodeID: node.id),
                    severity: .warning,
                    message: "\(label): this agent has no display name.",
                    nodeID: node.id))
            }

            let directory = node.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            if directory.isEmpty {
                issues.append(ValidationIssue(
                    kind: .emptyWorkingDirectory(nodeID: node.id),
                    severity: .error,
                    message: "\(label): choose a working directory.",
                    nodeID: node.id))
            } else if !directory.hasPrefix("/") && !directory.hasPrefix("~") {
                issues.append(ValidationIssue(
                    kind: .relativeWorkingDirectory(nodeID: node.id, path: directory),
                    severity: .error,
                    message: "\(label): working directory must be an absolute path, not \u{22}\(directory)\u{22}.",
                    nodeID: node.id))
            }

            for contactID in node.contactIDs.sorted(by: { contactOrder($0, $1, in: topology) }) {
                if contactID == node.id {
                    issues.append(ValidationIssue(
                        kind: .selfContact(nodeID: node.id),
                        severity: .warning,
                        message: "\(label): an agent does not need permission to talk to itself.",
                        nodeID: node.id))
                } else if !topology.contains(contactID) {
                    issues.append(ValidationIssue(
                        kind: .missingContact(nodeID: node.id, contactID: contactID),
                        severity: .error,
                        message: "\(label): allowed contact no longer exists in this team.",
                        nodeID: node.id))
                }
            }

            if !node.acceptsAgentMessages {
                // A terminal is a shell: no prompt is sent to it, so none is
                // needed, and one being set is not a problem either.
            } else if let templateID = node.promptTemplateID {
                if !promptTemplates.contains(where: { $0.id == templateID }) {
                    issues.append(ValidationIssue(
                        kind: .missingPromptTemplate(nodeID: node.id, templateID: templateID),
                        severity: .error,
                        message: "\(label): its role prompt template is missing.",
                        nodeID: node.id))
                }
            } else {
                issues.append(ValidationIssue(
                    kind: .unassignedPromptTemplate(nodeID: node.id),
                    severity: .warning,
                    message: "\(label): no role prompt assigned, so it starts with no instructions.",
                    nodeID: node.id))
            }
        }
        return issues
    }

    private static func sessionNameIssues(_ topology: Topology) -> [ValidationIssue] {
        var byName: [String: [UUID]] = [:]
        var order: [String] = []
        for node in topology.nodes {
            if byName[node.sessionName] == nil { order.append(node.sessionName) }
            byName[node.sessionName, default: []].append(node.id)
        }
        return order.compactMap { name in
            guard let ids = byName[name], ids.count > 1 else { return nil }
            return ValidationIssue(
                kind: .duplicateSessionName(name: name, nodeIDs: ids),
                severity: .error,
                message: "\(ids.count) agents share the tmux session name \u{22}\(name)\u{22}.",
                nodeID: ids.first)
        }
    }

    private static func reportingIssues(_ topology: Topology) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []

        for node in topology.nodes {
            guard let parentID = node.parentID else { continue }
            let label = displayLabel(node)

            if parentID == node.id {
                issues.append(ValidationIssue(
                    kind: .selfParent(nodeID: node.id),
                    severity: .error,
                    message: "\(label): an agent cannot report to itself.",
                    nodeID: node.id))
                continue
            }
            guard let parent = topology.node(parentID) else {
                issues.append(ValidationIssue(
                    kind: .missingParent(nodeID: node.id, parentID: parentID),
                    severity: .error,
                    message: "\(label): its manager is not part of this team.",
                    nodeID: node.id))
                continue
            }
            if parent.kind != .manager {
                issues.append(ValidationIssue(
                    kind: .parentIsNotManager(nodeID: node.id, parentID: parentID),
                    severity: .error,
                    message: "\(label): reports to \(displayLabel(parent)), which is a worker. Only managers take reports.",
                    nodeID: node.id))
            }
        }

        for cycle in cycles(in: topology) {
            let names = cycle.compactMap { topology.node($0)?.displayName }.joined(separator: " → ")
            issues.append(ValidationIssue(
                kind: .reportingCycle(nodeIDs: cycle),
                severity: .error,
                message: "Reporting loop: \(names) → \(topology.node(cycle[0])?.displayName ?? "?").",
                nodeID: cycle.first))
        }

        return issues
    }

    /// Every reporting loop, each reported once, listed from its
    /// earliest-in-topology-order member.
    private static func cycles(in topology: Topology) -> [[UUID]] {
        enum Mark { case visiting, done }
        var marks: [UUID: Mark] = [:]
        var found: [[UUID]] = []
        var reported: Set<Set<UUID>> = []

        for start in topology.nodes {
            guard marks[start.id] == nil else { continue }
            var path: [UUID] = []
            var cursor: UUID? = start.id

            while let current = cursor {
                if marks[current] == .done { break }
                if marks[current] == .visiting {
                    // Found a loop; it starts at the first occurrence in `path`.
                    if let begin = path.firstIndex(of: current) {
                        let loop = Array(path[begin...])
                        if reported.insert(Set(loop)).inserted {
                            found.append(canonicalize(loop, in: topology))
                        }
                    }
                    break
                }
                marks[current] = .visiting
                path.append(current)
                guard let node = topology.node(current), let parentID = node.parentID,
                      parentID != current, topology.contains(parentID)
                else { break }
                cursor = parentID
            }

            for id in path { marks[id] = .done }
        }
        return found
    }

    /// Rotates a loop so it starts at its earliest member in topology order,
    /// which keeps the reported message stable regardless of traversal start.
    private static func canonicalize(_ loop: [UUID], in topology: Topology) -> [UUID] {
        guard let startIndex = loop.indices.min(by: { a, b in
            (topology.index(of: loop[a]) ?? .max) < (topology.index(of: loop[b]) ?? .max)
        }) else { return loop }
        return Array(loop[startIndex...] + loop[..<startIndex])
    }

    private static func templateIssues(
        _ topology: Topology,
        promptTemplates: [PromptTemplate]
    ) -> [ValidationIssue] {
        var checked: Set<UUID> = []
        var issues: [ValidationIssue] = []
        for node in topology.nodes {
            guard let templateID = node.promptTemplateID, checked.insert(templateID).inserted,
                  let template = promptTemplates.first(where: { $0.id == templateID })
            else { continue }
            issues += validate(template: template)
        }
        return issues
    }

    // MARK: - Helpers

    private static func issue(for error: PromptTemplateError, templateID: UUID) -> ValidationIssue {
        switch error {
        case .unknownVariable(let name, _):
            return ValidationIssue(
                kind: .malformedPromptVariable(templateID: templateID, variable: name),
                severity: .error,
                message: error.description)
        default:
            return ValidationIssue(
                kind: .malformedPromptTemplate(templateID: templateID, detail: error.description),
                severity: .error,
                message: error.description)
        }
    }

    private static func displayLabel(_ node: AgentNode) -> String {
        let name = node.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? node.sessionName : name
    }

    private static func contactOrder(_ a: UUID, _ b: UUID, in topology: Topology) -> Bool {
        (topology.index(of: a) ?? .max) < (topology.index(of: b) ?? .max)
    }

    private static func orderIndex(_ issue: ValidationIssue, in topology: Topology) -> Int {
        guard let nodeID = issue.nodeID, let index = topology.index(of: nodeID) else { return .max }
        return index
    }
}
