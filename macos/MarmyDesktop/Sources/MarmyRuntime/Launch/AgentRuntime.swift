import Foundation
import MarmyCore

public enum RuntimeError: Error, CustomStringConvertible, Equatable {
    case notBound(nodeID: UUID)
    case identityMismatch(detail: String)
    case sessionNotFound(name: String)
    case sessionAlreadyBound(name: String, nodeID: UUID)
    case launchBlocked(reasons: [String])
    case agentExitedImmediately(sessionName: String, detail: String)
    case paneNotVisible(sessionName: String)
    case readOnly(detail: String)
    case terminalNotAttached
    case terminalShowingSomethingElse(expected: String, actual: String)
    case emptyMessage

    public var description: String {
        switch self {
        case .notBound(let nodeID):
            return "This agent is not attached to a running session (\(nodeID.uuidString))."
        case .identityMismatch(let detail):
            return "The session this agent was attached to is gone. \(detail) "
                + "Reconnect it or start a new one; nothing was sent."
        case .sessionNotFound(let name):
            return "No tmux session named \u{22}\(name)\u{22} is running."
        case .sessionAlreadyBound(let name, _):
            return "\u{22}\(name)\u{22} is already attached to another agent in this team."
        case .launchBlocked(let reasons):
            return "Nothing was started. \(reasons.joined(separator: " "))"
        case .agentExitedImmediately(let sessionName, let detail):
            return "\(sessionName) started but stopped straight away. \(detail)"
        case .paneNotVisible(let sessionName):
            return "The agent's pane is not the one showing in \u{22}\(sessionName)\u{22}. "
                + "Switch back to it in tmux, then send again; nothing was sent."
        case .readOnly(let detail):
            return "Marmy is not controlling tmux right now, so nothing was started, attached, or sent. \(detail)"
        case .terminalNotAttached:
            return "This terminal is no longer attached to tmux. Reconnect it, then send again; "
                + "nothing was sent."
        case .terminalShowingSomethingElse(let expected, let actual):
            return "The terminal is showing \u{22}\(actual)\u{22}, not \u{22}\(expected)\u{22}. "
                + "Switch it back or reconnect, then send again; nothing was sent."
        case .emptyMessage:
            return "There is nothing to send."
        }
    }
}

/// What one launch attempt did.
public struct LaunchOutcome: Sendable {
    public var preflight: PreflightReport
    /// Nodes started by this attempt, in the order they were started.
    public var started: [UUID: AgentBinding]
    /// Nodes that failed, with the reason. Everything else still started.
    public var failures: [UUID: String]
    /// Nodes deliberately left alone, with why.
    public var skipped: [UUID: String]

    public init(
        preflight: PreflightReport,
        started: [UUID: AgentBinding] = [:],
        failures: [UUID: String] = [:],
        skipped: [UUID: String] = [:]
    ) {
        self.preflight = preflight
        self.started = started
        self.failures = failures
        self.skipped = skipped
    }

    public var isFullSuccess: Bool { failures.isEmpty && !preflight.isBlocked }
}

/// Owns Marmy's view of live agents: what is running, what to start, and how to
/// talk to it.
///
/// An actor because the UI calls it from anywhere and every operation ends in a
/// subprocess. It never kills a session it was not explicitly asked to, never
/// takes over a session it did not start, and never sends text to a pane whose
/// identity it has not just re-checked.
public actor AgentRuntime {
    /// Exposed so the UI can attach a terminal client to the same server.
    public nonisolated let tmux: TmuxClient
    private let locator: ExecutableLocator
    private let store: RuntimeStore
    private let trampoline: TrampolineCommand
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID

    private var ledger: RuntimeLedger
    private var launching: Set<UUID> = []
    /// True when the ledger could not be read. Reading tmux still works, so the
    /// user can see what is running; nothing may be changed or written.
    private let readOnlyReason: String?

    public init(
        tmux: TmuxClient,
        locator: ExecutableLocator = ExecutableLocator(),
        store: RuntimeStore,
        trampoline: TrampolineCommand = .resolveDefault(),
        now: @escaping @Sendable () -> Date = { Date() },
        makeID: @escaping @Sendable () -> UUID = { UUID() }
    ) throws {
        self.tmux = tmux
        self.locator = locator
        self.store = store
        self.trampoline = trampoline
        self.now = now
        self.makeID = makeID
        self.ledger = try store.loadLedger()
        self.readOnlyReason = nil
    }

    /// A runtime that can look but not touch.
    ///
    /// Used when the ledger will not load: the real store is kept — never
    /// swapped for scratch storage — and every action that would start, attach,
    /// message, or record anything is refused with the reason.
    public init(
        readOnly reason: String,
        tmux: TmuxClient,
        locator: ExecutableLocator = ExecutableLocator(),
        store: RuntimeStore,
        trampoline: TrampolineCommand = .resolveDefault(),
        now: @escaping @Sendable () -> Date = { Date() },
        makeID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.tmux = tmux
        self.locator = locator
        self.store = store
        self.trampoline = trampoline
        self.now = now
        self.makeID = makeID
        self.ledger = RuntimeLedger()
        self.readOnlyReason = reason
    }

    private func requireWritable() throws {
        if let readOnlyReason { throw RuntimeError.readOnly(detail: readOnlyReason) }
    }

    // MARK: - What Marmy knows

    public func bindings() -> [AgentBinding] { ledger.bindings }

    public func binding(for nodeID: UUID) -> AgentBinding? { ledger.binding(nodeID: nodeID) }

    /// Forgets Marmy's record of a node. The tmux session keeps running: closing
    /// a team in the app is never a reason to end someone's work.
    @discardableResult
    public func forget(nodeID: UUID) throws -> AgentBinding? {
        try requireWritable()
        let removed = ledger.remove(nodeID: nodeID)
        if removed != nil { try store.saveLedger(ledger) }
        return removed
    }

    /// Live state of every node in a team.
    public func snapshot(topology: Topology) async throws -> RuntimeSnapshot {
        let server = try await tmux.serverIdentity()
        let sessions = try await tmux.listSessions()
        let panes = try await tmux.listPanes()

        var states: [UUID: AgentRuntimeState] = [:]
        for node in topology.nodes {
            if launching.contains(node.id) {
                states[node.id] = .launching
            } else if let binding = ledger.binding(nodeID: node.id) {
                states[node.id] = LiveIdentity.state(
                    for: binding, server: server, panes: panes, sessions: sessions)
            } else {
                states[node.id] = .notLaunched
            }
        }
        return RuntimeSnapshot(states: states, sessions: sessions, panes: panes, server: server)
    }

    /// Sessions on this server that no node in `topology` is bound to.
    public func unassignedSessions(topology: Topology) async throws -> [TmuxSession] {
        let snapshot = try await snapshot(topology: topology)
        let bound = Set(topology.nodes.compactMap { ledger.binding(nodeID: $0.id)?.sessionID })
        return snapshot.unassignedSessions(boundSessionIDs: bound)
    }

    // MARK: - Preflight and launch

    public func preflight(
        topology: Topology,
        workspace: Workspace,
        nodeIDs: Set<UUID>? = nil
    ) async -> PreflightReport {
        do {
            let snapshot = try await snapshot(topology: topology)
            return LaunchPreflight.evaluate(
                topology: topology,
                workspace: workspace,
                requestedNodeIDs: nodeIDs,
                liveSessions: snapshot.sessions,
                states: snapshot.states,
                bindings: bindingsByNode(topology),
                locator: locator,
                trampoline: trampoline,
                server: tmux.server)
        } catch {
            return PreflightReport(findings: [PreflightFinding(
                kind: .tmuxUnavailable(detail: "\(error)"),
                severity: .error,
                message: "Could not read tmux state: \(error)")])
        }
    }

    /// Starts every node that needs starting, after the whole team passes
    /// preflight.
    ///
    /// A blocked preflight starts nothing at all. A failure partway through
    /// keeps every session that did start, records it, and reports exactly what
    /// failed, so a retry only starts what is still absent.
    public func launch(
        topology: Topology,
        workspace: Workspace,
        nodeIDs: Set<UUID>? = nil
    ) async -> LaunchOutcome {
        if let readOnlyReason {
            return LaunchOutcome(preflight: PreflightReport(findings: [PreflightFinding(
                kind: .tmuxUnavailable(detail: readOnlyReason),
                severity: .error,
                message: "\(RuntimeError.readOnly(detail: readOnlyReason))")]))
        }
        let report = await preflight(topology: topology, workspace: workspace, nodeIDs: nodeIDs)
        var outcome = LaunchOutcome(preflight: report)
        for (nodeID, sessionName) in report.alreadyRunning {
            outcome.skipped[nodeID] = "already running in \(sessionName)"
        }
        guard !report.isBlocked else { return outcome }

        store.sweepStaleSpecs()

        for plan in report.plans {
            guard let node = topology.node(plan.nodeID) else { continue }
            launching.insert(plan.nodeID)
            defer { launching.remove(plan.nodeID) }

            do {
                outcome.started[plan.nodeID] = try await start(plan: plan, node: node, topology: topology)
            } catch {
                outcome.failures[plan.nodeID] = "\(error)"
            }
        }
        return outcome
    }

    private func start(plan: NodeLaunchPlan, node: AgentNode, topology: Topology) async throws -> AgentBinding {
        let generation = makeID()
        let spec = LaunchSpec(
            executablePath: plan.executablePath,
            arguments: plan.arguments,
            workingDirectory: plan.workingDirectory,
            environmentAdditions: ["PATH": locator.launchPATH],
            environmentRemovals: plan.environmentRemovals,
            topologyID: topology.id,
            nodeID: node.id,
            generation: generation)

        let specURL = try store.writeSpec(spec)
        let started: TmuxStartedSession
        do {
            started = try await tmux.newSession(
                name: plan.sessionName,
                directory: plan.workingDirectory,
                executable: trampoline.executablePath,
                arguments: trampoline.arguments(specPath: specURL.path))
        } catch {
            // Nothing is running, so the spec is safe to remove immediately.
            removeLaunchArtifacts(specURL: specURL)
            throw error
        }

        // tmux reports success as soon as the pane exists; a spec or exec
        // failure ends the pane milliseconds later. Nothing is recorded as
        // running until the pane is confirmed alive.
        try await confirmAlive(started, specURL: specURL)

        guard let server = try await tmux.serverIdentity() else {
            throw TmuxError.commandFailed(
                command: "display-message", detail: "the session started but the server did not report itself")
        }

        let binding = AgentBinding(
            topologyID: topology.id,
            nodeID: node.id,
            generation: generation,
            sessionName: started.sessionName,
            sessionID: started.sessionID,
            paneID: started.paneID,
            server: server,
            ownership: .launched,
            cli: node.cli,
            startedAt: now())

        // Session-scoped marker so ownership survives losing the ledger. Best
        // effort: a session that is running matters more than its label.
        try? await tmux.setSessionOption(
            AgentBinding.ownershipOptionName, value: binding.ownershipMarker, target: started.sessionID)

        ledger.upsert(binding)
        try store.saveLedger(ledger)
        removeLaunchArtifacts(specURL: specURL)
        return binding
    }

    /// Confirms the pane tmux just created is still running the agent.
    private func confirmAlive(_ started: TmuxStartedSession, specURL: URL) async throws {
        try? await Task.sleep(nanoseconds: 200_000_000)
        let panes = try await tmux.listPanes()
        let pane = panes.first { $0.id == started.paneID }
        guard let pane, !pane.isDead else {
            let detail = readLaunchError(specURL: specURL)
                ?? "Check that the CLI runs in that folder."
            removeLaunchArtifacts(specURL: specURL)
            throw RuntimeError.agentExitedImmediately(sessionName: started.sessionName, detail: detail)
        }
    }

    /// The reason a trampoline left behind before its pane disappeared.
    private func readLaunchError(specURL: URL) -> String? {
        let path = AgentTrampoline.errorPath(forSpecAt: specURL.path)
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func removeLaunchArtifacts(specURL: URL) {
        store.removeSpec(at: specURL)
        try? FileManager.default.removeItem(atPath: AgentTrampoline.errorPath(forSpecAt: specURL.path))
    }

    // MARK: - Adoption

    /// Attaches an existing session to a node because the user said to.
    ///
    /// No prompt is sent, no keys are typed, and no option is set on the
    /// session: an already-running agent — or a plain shell — is left exactly as
    /// it is.
    @discardableResult
    public func adopt(
        sessionName: String,
        nodeID: UUID,
        topology: Topology,
        cli: AgentCLI?
    ) async throws -> AgentBinding {
        try requireWritable()
        let sessions = try await tmux.listSessions()
        guard let session = sessions.first(where: { $0.name == sessionName }) else {
            throw RuntimeError.sessionNotFound(name: sessionName)
        }
        guard let server = try await tmux.serverIdentity() else {
            throw RuntimeError.sessionNotFound(name: sessionName)
        }
        // Session ids are only unique within one running server, so a binding
        // from a server that has since restarted must not block this adoption.
        if let clash = ledger.bindings.first(where: {
            $0.sessionID == session.id && $0.nodeID != nodeID && $0.server == server
        }) {
            throw RuntimeError.sessionAlreadyBound(name: sessionName, nodeID: clash.nodeID)
        }
        let panes = try await tmux.listPanes()
        guard let pane = panes.first(where: { $0.sessionID == session.id && $0.isActive && $0.isWindowActive })
            ?? panes.first(where: { $0.sessionID == session.id })
        else {
            throw RuntimeError.sessionNotFound(name: sessionName)
        }

        let binding = AgentBinding(
            topologyID: topology.id,
            nodeID: nodeID,
            generation: makeID(),
            sessionName: session.name,
            sessionID: session.id,
            paneID: pane.id,
            server: server,
            ownership: .adopted,
            cli: cli,
            startedAt: now())
        ledger.upsert(binding)
        try store.saveLedger(ledger)
        return binding
    }

    // MARK: - Sending

    /// Sends one message to the pane a node is bound to.
    ///
    /// The pane id is re-validated against the live server first, so a session
    /// that ended — or a different one that took its name — gets an error rather
    /// than someone else's terminal receiving the text. The message travels
    /// through a private tmux buffer, never through a command line.
    /// `fromClient` is the PID of the embedded terminal's tmux client, when the
    /// message is being sent from a terminal the user is looking at.
    public func send(_ text: String, toNode nodeID: UUID, fromClient clientPID: Int32? = nil) async throws {
        try requireWritable()
        guard !text.isEmpty else { throw RuntimeError.emptyMessage }
        guard let binding = ledger.binding(nodeID: nodeID) else {
            throw RuntimeError.notBound(nodeID: nodeID)
        }

        let server = try await tmux.serverIdentity()
        let panes = try await tmux.listPanes()
        let sessions = try await tmux.listSessions()
        let state = LiveIdentity.state(for: binding, server: server, panes: panes, sessions: sessions)
        guard case .running = state else {
            if case .missing(let reason) = state { throw RuntimeError.identityMismatch(detail: reason) }
            throw RuntimeError.identityMismatch(detail: "The pane is not available.")
        }
        try requireVisible(paneID: binding.paneID, in: panes, sessionName: binding.sessionName)
        try await requireClientIsShowing(
            sessionID: binding.sessionID, paneID: binding.paneID,
            sessionName: binding.sessionName, clientPID: clientPID)
        try await deliver(text, to: binding.paneID)
    }

    /// Sends to a live session the user opened directly, without adding it to a
    /// team.
    ///
    /// The session id is checked against the live server first, so a session
    /// that ended — or a new one that took its name — is refused rather than
    /// typed into. Nothing is recorded and no bootstrap is ever sent.
    public func send(
        _ text: String,
        toSessionID sessionID: String,
        onServer expectedServer: TmuxServerIdentity? = nil,
        expectedPaneID: String? = nil,
        fromClient clientPID: Int32? = nil
    ) async throws {
        try requireWritable()
        guard !text.isEmpty else { throw RuntimeError.emptyMessage }
        if let expectedServer {
            // Session ids restart with the server, so the server this session was
            // opened on is part of its identity.
            let current = try await tmux.serverIdentity()
            guard current == expectedServer else {
                throw RuntimeError.identityMismatch(
                    detail: "tmux has restarted since this session was opened.")
            }
        }
        let sessions = try await tmux.listSessions()
        guard let session = sessions.first(where: { $0.id == sessionID }) else {
            throw RuntimeError.identityMismatch(detail: "Session \(sessionID) is no longer running.")
        }
        let panes = try await tmux.listPanes()
        guard let pane = panes.first(where: { $0.sessionID == sessionID && $0.isActive && $0.isWindowActive }) else {
            throw RuntimeError.paneNotVisible(sessionName: session.name)
        }
        if let expectedPaneID, expectedPaneID != pane.id {
            // The pane this session was opened on is not the one on screen now.
            throw RuntimeError.paneNotVisible(sessionName: session.name)
        }
        try await requireClientIsShowing(
            sessionID: sessionID, paneID: pane.id, sessionName: session.name, clientPID: clientPID)
        try await deliver(text, to: pane.id)
    }

    /// Confirms the embedded terminal is still looking at this session and pane.
    ///
    /// A user can switch sessions from inside tmux, and then the pane on screen
    /// is not the agent's. Delivering anyway would type into whatever they
    /// switched to, so this refuses instead.
    private func requireClientIsShowing(
        sessionID: String,
        paneID: String,
        sessionName: String,
        clientPID: Int32?
    ) async throws {
        guard let clientPID else { return }
        let clients = try await tmux.listClients()
        guard let client = clients.first(where: { $0.pid == clientPID }) else {
            throw RuntimeError.terminalNotAttached
        }
        guard client.sessionID == sessionID else {
            throw RuntimeError.terminalShowingSomethingElse(
                expected: sessionName, actual: client.sessionName)
        }
        guard client.paneID == paneID else {
            throw RuntimeError.paneNotVisible(sessionName: sessionName)
        }
    }

    /// Refuses to type into a pane that is not the one on screen in its session.
    private nonisolated func requireVisible(
        paneID: String,
        in panes: [TmuxPane],
        sessionName: String
    ) throws {
        guard let pane = panes.first(where: { $0.id == paneID }) else {
            throw RuntimeError.identityMismatch(detail: "Pane \(paneID) is gone.")
        }
        guard pane.isActive, pane.isWindowActive else {
            throw RuntimeError.paneNotVisible(sessionName: sessionName)
        }
    }

    /// The message travels as a private buffer, so the text is never parsed as a
    /// command by tmux or by a shell.
    private func deliver(_ text: String, to paneID: String) async throws {
        let bufferName = "marmy-\(makeID().uuidString.lowercased())"
        try await tmux.loadBuffer(name: bufferName, text: text)
        do {
            // paste-buffer -d removes the buffer itself on success.
            try await tmux.pasteBuffer(name: bufferName, target: paneID)
            try await tmux.sendEnter(target: paneID)
        } catch {
            try? await tmux.deleteBuffer(name: bufferName)
            throw error
        }
    }

    /// One round trip describing everything live, so the UI can work out the
    /// state of every team without a request per team.
    public func readout() async throws -> RuntimeReadout {
        RuntimeReadout(
            server: try await tmux.serverIdentity(),
            sessions: try await tmux.listSessions(),
            panes: try await tmux.listPanes(),
            bindings: ledger.bindings,
            launching: launching)
    }

    /// Every session on this server, for the sidebar's list of local sessions.
    public func liveSessions() async throws -> [TmuxSession] {
        try await tmux.listSessions()
    }

    /// Session ids any saved team is bound to.
    public func boundSessionIDs() -> Set<String> {
        Set(ledger.bindings.map(\.sessionID))
    }

    // MARK: - Helpers

    private func bindingsByNode(_ topology: Topology) -> [UUID: AgentBinding] {
        var result: [UUID: AgentBinding] = [:]
        for node in topology.nodes {
            if let binding = ledger.binding(nodeID: node.id) { result[node.id] = binding }
        }
        return result
    }
}

/// A snapshot of everything live on the tmux server plus what Marmy has bound.
public struct RuntimeReadout: Sendable {
    public var server: TmuxServerIdentity?
    public var sessions: [TmuxSession]
    public var panes: [TmuxPane]
    public var bindings: [AgentBinding]
    public var launching: Set<UUID>

    public init(
        server: TmuxServerIdentity?,
        sessions: [TmuxSession],
        panes: [TmuxPane],
        bindings: [AgentBinding],
        launching: Set<UUID> = []
    ) {
        self.server = server
        self.sessions = sessions
        self.panes = panes
        self.bindings = bindings
        self.launching = launching
    }

    public func binding(nodeID: UUID) -> AgentBinding? {
        bindings.first { $0.nodeID == nodeID }
    }

    /// State of one node, worked out from what is live right now.
    public func state(of nodeID: UUID) -> AgentRuntimeState {
        if launching.contains(nodeID) { return .launching }
        guard let binding = binding(nodeID: nodeID) else { return .notLaunched }
        return LiveIdentity.state(for: binding, server: server, panes: panes, sessions: sessions)
    }

    /// Session ids Marmy is bound to on the server in front of us. Bindings
    /// recorded against an older server are stale and must not hide a live
    /// session that happens to reuse the id.
    public var boundSessionIDs: Set<String> {
        guard let server else { return [] }
        return Set(bindings.filter { $0.server == server }.map(\.sessionID))
    }
}

/// Decides whether a recorded binding still points at the same live thing.
public enum LiveIdentity {

    public static func state(
        for binding: AgentBinding,
        server: TmuxServerIdentity?,
        panes: [TmuxPane],
        sessions: [TmuxSession]
    ) -> AgentRuntimeState {
        let adopted = binding.ownership == .adopted

        guard let server else {
            return .missing(reason: "The tmux server is no longer running.")
        }
        guard server == binding.server else {
            return .missing(reason: "tmux has been restarted since \(binding.sessionName) was attached.")
        }
        guard let pane = panes.first(where: { $0.id == binding.paneID }) else {
            if let replacement = sessions.first(where: { $0.name == binding.sessionName }),
               replacement.id != binding.sessionID {
                return .missing(reason:
                    "A different session is now called \u{22}\(binding.sessionName)\u{22} (\(replacement.id)).")
            }
            return .missing(reason: "Session \u{22}\(binding.sessionName)\u{22} has ended.")
        }
        guard pane.sessionID == binding.sessionID else {
            return .missing(reason: "Pane \(binding.paneID) now belongs to \(pane.sessionName).")
        }
        guard !pane.isDead else {
            return .missing(reason: "The agent in \u{22}\(pane.sessionName)\u{22} has exited.")
        }
        return .running(paneID: pane.id, sessionName: pane.sessionName, adopted: adopted)
    }
}
