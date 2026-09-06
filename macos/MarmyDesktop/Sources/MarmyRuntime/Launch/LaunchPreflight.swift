import Foundation
import MarmyCore

/// One thing preflight found. Errors block the whole launch; warnings are worth
/// showing but start nothing and stop nothing.
public struct PreflightFinding: Sendable, Equatable {
    public enum Severity: Sendable, Equatable {
        case error
        case warning
    }

    public enum Kind: Sendable, Equatable {
        case topologyInvalid(detail: String)
        case promptRenderFailed(detail: String)
        case workingDirectoryMissing(path: String)
        case workingDirectoryNotADirectory(path: String)
        case cliMissing(name: String)
        case sessionNameInUse(name: String, sessionID: String)
        case alreadyRunning(sessionName: String)
        case bindingLost(detail: String)
        case trampolineMissing(path: String)
        case tmuxUnavailable(detail: String)
    }

    public var kind: Kind
    public var severity: Severity
    public var message: String
    public var nodeID: UUID?

    public init(kind: Kind, severity: Severity, message: String, nodeID: UUID? = nil) {
        self.kind = kind
        self.severity = severity
        self.message = message
        self.nodeID = nodeID
    }
}

/// Everything needed to start one node, worked out before anything is mutated.
public struct NodeLaunchPlan: Sendable, Equatable {
    public var nodeID: UUID
    public var sessionName: String
    public var executablePath: String
    public var arguments: [String]
    public var workingDirectory: String
    public var initialPrompt: String
    public var environmentRemovals: [String]
}

public struct PreflightReport: Sendable {
    public var findings: [PreflightFinding]
    /// Nodes that would be started, in topology order.
    public var plans: [NodeLaunchPlan]
    /// Nodes already alive, which a launch leaves completely alone.
    public var alreadyRunning: [UUID: String]

    public init(
        findings: [PreflightFinding] = [],
        plans: [NodeLaunchPlan] = [],
        alreadyRunning: [UUID: String] = [:]
    ) {
        self.findings = findings
        self.plans = plans
        self.alreadyRunning = alreadyRunning
    }

    public var errors: [PreflightFinding] { findings.filter { $0.severity == .error } }
    public var warnings: [PreflightFinding] { findings.filter { $0.severity == .warning } }
    /// Nothing is started while this is true.
    public var isBlocked: Bool { !errors.isEmpty }
}

/// Checks a whole team before a single tmux command runs.
///
/// It is a pure function of the inputs, so every failure mode is testable
/// without a tmux server, and so the launcher can refuse to mutate anything
/// when something is wrong.
public enum LaunchPreflight {

    public static func evaluate(
        topology: Topology,
        workspace: Workspace,
        requestedNodeIDs: Set<UUID>? = nil,
        liveSessions: [TmuxSession],
        states: [UUID: AgentRuntimeState],
        bindings: [UUID: AgentBinding],
        locator: ExecutableLocator,
        trampoline: TrampolineCommand,
        server: TmuxServerAddress = .userDefault,
        fileManager: FileManager = .default
    ) -> PreflightReport {
        var report = PreflightReport()

        // The whole team is validated, not just the part being started: a broken
        // reporting graph makes every rendered prompt wrong.
        for issue in TopologyValidator.validate(topology, promptTemplates: workspace.promptTemplates).errors {
            report.findings.append(PreflightFinding(
                kind: .topologyInvalid(detail: issue.message),
                severity: .error,
                message: issue.message,
                nodeID: issue.nodeID))
        }

        if !fileManager.isExecutableFile(atPath: trampoline.executablePath) {
            report.findings.append(PreflightFinding(
                kind: .trampolineMissing(path: trampoline.executablePath),
                severity: .error,
                message: "The agent launcher is missing at \(trampoline.executablePath). Rebuild Marmy Desktop."))
        }

        let resolvedNames = resolvedSessionNames(topology: topology, states: states)
        let sessionsByName = Dictionary(liveSessions.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        for node in topology.nodes {
            guard requestedNodeIDs?.contains(node.id) ?? true else { continue }
            let label = node.displayName.isEmpty ? node.sessionName : node.displayName
            let state = states[node.id] ?? .notLaunched

            if case .running(_, let sessionName, _) = state {
                report.alreadyRunning[node.id] = sessionName
                report.findings.append(PreflightFinding(
                    kind: .alreadyRunning(sessionName: sessionName),
                    severity: .warning,
                    message: "\(label) is already running in \(sessionName); it will be left alone.",
                    nodeID: node.id))
                continue
            }
            if case .missing(let reason) = state {
                report.findings.append(PreflightFinding(
                    kind: .bindingLost(detail: reason),
                    severity: .warning,
                    message: "\(label): \(reason) A fresh session will be started.",
                    nodeID: node.id))
            }

            var nodeFailed = false

            // Working directory.
            let directory = NSString(string: node.workingDirectory).expandingTildeInPath
            var isDirectory: ObjCBool = false
            if !fileManager.fileExists(atPath: directory, isDirectory: &isDirectory) {
                report.findings.append(PreflightFinding(
                    kind: .workingDirectoryMissing(path: directory),
                    severity: .error,
                    message: "\(label): \(directory) does not exist.",
                    nodeID: node.id))
                nodeFailed = true
            } else if !isDirectory.boolValue {
                report.findings.append(PreflightFinding(
                    kind: .workingDirectoryNotADirectory(path: directory),
                    severity: .error,
                    message: "\(label): \(directory) is a file, not a folder.",
                    nodeID: node.id))
                nodeFailed = true
            }

            // CLI availability.
            var executablePath = ""
            do {
                executablePath = try locator.locateOrThrow(node.cli.executableName)
            } catch {
                report.findings.append(PreflightFinding(
                    kind: .cliMissing(name: node.cli.executableName),
                    severity: .error,
                    message: "\(label): \(error)",
                    nodeID: node.id))
                nodeFailed = true
            }

            // Session name still free. A live session with this name that is not
            // this node's own is a collision: Marmy never takes it over.
            if let existing = sessionsByName[node.sessionName] {
                report.findings.append(PreflightFinding(
                    kind: .sessionNameInUse(name: node.sessionName, sessionID: existing.id),
                    severity: .error,
                    message: "\(label): a tmux session named \u{22}\(node.sessionName)\u{22} is already running "
                        + "(\(existing.id)). Rename this agent, or attach that session to it instead.",
                    nodeID: node.id))
                nodeFailed = true
            }

            // Rendered prompt.
            var prompt = ""
            do {
                prompt = try BootstrapPrompt.render(
                    for: node, in: topology, workspace: workspace,
                    server: server, resolvedSessionNames: resolvedNames)
            } catch {
                report.findings.append(PreflightFinding(
                    kind: .promptRenderFailed(detail: "\(error)"),
                    severity: .error,
                    message: "\(label): its role prompt could not be rendered. \(error)",
                    nodeID: node.id))
                nodeFailed = true
            }

            if prompt.contains("\0") {
                report.findings.append(PreflightFinding(
                    kind: .promptRenderFailed(detail: "the prompt contains a NUL character"),
                    severity: .error,
                    message: "\(label): its prompt contains a NUL character, which cannot be passed to a CLI.",
                    nodeID: node.id))
                nodeFailed = true
            }

            guard !nodeFailed else { continue }
            report.plans.append(NodeLaunchPlan(
                nodeID: node.id,
                sessionName: node.sessionName,
                executablePath: executablePath,
                arguments: AgentCommand.arguments(
                    for: node, initialPrompt: prompt, workingDirectory: directory),
                workingDirectory: directory,
                initialPrompt: prompt,
                environmentRemovals: AgentCommand.environmentRemovals(for: node)))
        }

        return report
    }

    /// Where each node is reachable right now.
    ///
    /// A node that is running is addressed by the name its live session
    /// currently has — that is where messages actually land. Anything else is
    /// addressed by the name it is about to be launched under, so a stale
    /// attachment from a previous run never appears in a fresh team's prompts.
    public static func resolvedSessionNames(
        topology: Topology,
        states: [UUID: AgentRuntimeState]
    ) -> [UUID: String] {
        var names: [UUID: String] = [:]
        for node in topology.nodes {
            if case .running(_, let sessionName, _) = states[node.id] ?? .notLaunched {
                names[node.id] = sessionName
            } else {
                names[node.id] = node.sessionName
            }
        }
        return names
    }
}
