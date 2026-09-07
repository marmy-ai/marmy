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
    case unsafeToInsert(reason: String)
    case deliveryUncertain(detail: String)
    case agentBusy(detail: String)
    case journalUnavailable(detail: String)
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
        case .unsafeToInsert(let reason):
            return reason
        case .deliveryUncertain(let detail):
            return "Marmy could not confirm what reached the agent: \(detail) "
                + "Look at the terminal before trying again — the text may already be there."
        case .agentBusy(let detail):
            return "This agent is not at an empty prompt: \(detail) The message is waiting."
        case .journalUnavailable(let detail):
            return "Marmy could not write this message down, so it was not sent: \(detail)"
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
    /// Nodes that did start, but with something the user should know about —
    /// a starting prompt whose delivery could not be written down, say. The
    /// agent is running either way.
    public var warnings: [UUID: String]

    public init(
        preflight: PreflightReport,
        started: [UUID: AgentBinding] = [:],
        failures: [UUID: String] = [:],
        skipped: [UUID: String] = [:],
        warnings: [UUID: String] = [:]
    ) {
        self.preflight = preflight
        self.started = started
        self.failures = failures
        self.skipped = skipped
        self.warnings = warnings
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
    /// Everything Marmy has said to an agent.
    public nonisolated let journal: MessageJournal
    private let trampoline: TrampolineCommand
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID

    private var ledger: RuntimeLedger
    private var launching: Set<UUID> = []
    /// Something worth saying about an agent that did start, collected by
    /// `start` and handed back with the outcome.
    private var launchWarnings: [UUID: String] = [:]
    /// Deliveries currently touching a pane, so they take turns.
    private var paneDeliveries: [String: Task<Void, Never>] = [:]
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
        self.journal = MessageJournal(directoryURL: store.directoryURL)
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
        self.journal = MessageJournal(directoryURL: store.directoryURL)
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
                if let warning = launchWarnings.removeValue(forKey: plan.nodeID) {
                    outcome.warnings[plan.nodeID] = warning
                }
            } catch {
                outcome.failures[plan.nodeID] = "\(error)"
                launchWarnings.removeValue(forKey: plan.nodeID)
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

        // What the agent is about to be told, written down before it is
        // started. If this cannot be recorded, nothing is started: an agent
        // holding instructions Marmy has no record of is worse than one that did
        // not start.
        var launchEntry: JournalEntry?
        if !plan.initialPrompt.isEmpty {
            let entry = JournalEntry(
                id: generation,
                kind: .launchPrompt,
                status: .prepared,
                createdAt: now(),
                topologyID: topology.id,
                nodeID: node.id,
                sessionName: plan.sessionName,
                sessionID: "",
                paneID: "",
                payload: plan.initialPrompt)
            do {
                try await journal.record(entry)
            } catch {
                throw RuntimeError.journalUnavailable(detail: "\(error)")
            }
            launchEntry = entry
        }

        let specURL = try store.writeSpec(spec)
        // The prompt travels with the process, so starting the process is the
        // moment of delivery. Marked before the spawn: a Marmy that stops during
        // startup leaves an attempt that is uncertain, not one that looks
        // untried.
        if let launchEntry {
            do {
                try await journal.update(launchEntry.id, status: .sending, now: now())
            } catch {
                removeLaunchArtifacts(specURL: specURL)
                throw RuntimeError.journalUnavailable(detail: "\(error)")
            }
        }
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
            if let launchEntry {
                try? await journal.update(
                    launchEntry.id, status: .failed, detail: "\(error)", now: now())
            }
            throw error
        }

        // tmux reports success as soon as the pane exists; a spec or exec
        // failure ends the pane milliseconds later. Nothing is recorded as
        // running until the pane is confirmed alive.
        let launchCommand: String
        do {
            launchCommand = try await confirmAlive(started, specURL: specURL)
        } catch {
            // The process was started with the prompt already in hand, so it may
            // have read it before it stopped. "Failed" would be a guess, and it
            // is the guess that invites sending it twice.
            if let launchEntry {
                try? await journal.finish(
                    launchEntry.id, status: .uncertain,
                    detail: "The agent was started with this prompt but did not stay running, so "
                        + "it is not known whether it read it. \(error)",
                    sessionID: started.sessionID, paneID: started.paneID,
                    generation: generation, now: now())
            }
            throw error
        }

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
            launchCommand: launchCommand,
            startedAt: now())

        // Session-scoped marker so ownership survives losing the ledger. Best
        // effort: a session that is running matters more than its label.
        try? await tmux.setSessionOption(
            AgentBinding.ownershipOptionName, value: binding.ownershipMarker, target: started.sessionID)

        ledger.upsert(binding)
        try store.saveLedger(ledger)
        removeLaunchArtifacts(specURL: specURL)

        // The prompt went with the process itself, so it is delivered the moment
        // the agent is up. Where it went and what became of it are written
        // together: an entry that claims delivery but names no recipient is not
        // a record of anything. If that write fails the entry stays `sending`,
        // which says what is true — the agent has the prompt and Marmy could
        // not record it — and the session it is running in is kept either way.
        if let launchEntry {
            do {
                try await journal.finish(
                    launchEntry.id, status: .submitted,
                    sessionID: started.sessionID, paneID: started.paneID,
                    server: server, generation: generation, now: now())
            } catch {
                // The agent is up and has the prompt; only the record of that
                // failed. The session is kept, and this is said out loud rather
                // than left as an entry that says it is still being sent.
                launchWarnings[node.id] =
                    "\(node.displayName) started and was given its starting prompt, but Marmy "
                        + "could not record that. Its message history will show the delivery as "
                        + "unconfirmed. \(error)"
            }
        }
        return binding
    }

    /// Confirms the pane tmux just created is still running the agent.
    /// Confirms the pane is alive, and reports what tmux calls the program in
    /// it — the name to compare against later, whatever it turns out to be.
    @discardableResult
    private func confirmAlive(_ started: TmuxStartedSession, specURL: URL) async throws -> String {
        try? await Task.sleep(nanoseconds: 200_000_000)
        var panes = try await tmux.listPanes()
        var pane = panes.first { $0.id == started.paneID }

        // The pane starts out running Marmy's launcher; the CLI replaces it a
        // moment later. Whatever is recorded has to be the CLI, so this waits
        // for the name to settle on something that is not the launcher.
        var attempts = 0
        while let current = pane, !current.isDead,
              AgentReadiness.disqualifyingCommands.contains(current.currentCommand),
              attempts < 8 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            panes = try await tmux.listPanes()
            pane = panes.first { $0.id == started.paneID }
            attempts += 1
        }

        guard let pane, !pane.isDead else {
            let detail = readLaunchError(specURL: specURL)
                ?? "Check that the CLI runs in that folder."
            removeLaunchArtifacts(specURL: specURL)
            throw RuntimeError.agentExitedImmediately(sessionName: started.sessionName, detail: detail)
        }
        // A name still in that list means Marmy could not establish what is
        // running; readiness treats that as "never automatic".
        return pane.currentCommand
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
    /// The exact live thing a delivery is for, as it was when the user acted.
    public struct DeliveryTarget: Sendable, Equatable {
        public var sessionID: String
        public var paneID: String
        public var server: TmuxServerIdentity
        /// The launch this pane belongs to, for a team member.
        public var generation: UUID?

        public init(
            sessionID: String,
            paneID: String,
            server: TmuxServerIdentity,
            generation: UUID? = nil
        ) {
            self.sessionID = sessionID
            self.paneID = paneID
            self.server = server
            self.generation = generation
        }
    }

    /// How far a delivery goes.
    public enum Delivery: Sendable, Equatable {
        /// Put the text in the agent's prompt and press Enter for them.
        case submit
        /// Put the text in the prompt and leave it there, for the user to read,
        /// edit, and send themselves.
        case insert
    }

    /// Puts text into an agent's prompt without pressing Enter.
    ///
    /// Used for dictation: the words go where the user can see and change them,
    /// and sending remains their decision. Everything else — the identity
    /// checks, the private buffer — is exactly as it is for a message.
    public func paste(
        _ text: String,
        toNode nodeID: UUID,
        expecting expected: DeliveryTarget,
        fromClient clientPID: Int32? = nil
    ) async throws {
        // Marmy is typing this, not the user: it has to be inert.
        if let refusal = InsertSafety.refusal(for: text) {
            throw RuntimeError.unsafeToInsert(reason: refusal.description)
        }
        try await withPane(expected.paneID) {
            try await self.verify(expected, nodeID: nodeID, clientPID: clientPID)
            try await self.deliver(text, to: expected.paneID, delivery: .insert)
        }
    }

    public func paste(
        _ text: String,
        toSessionID sessionID: String,
        expecting expected: DeliveryTarget,
        fromClient clientPID: Int32? = nil
    ) async throws {
        if let refusal = InsertSafety.refusal(for: text) {
            throw RuntimeError.unsafeToInsert(reason: refusal.description)
        }
        try await withPane(expected.paneID) {
            try await self.verify(expected, nodeID: nil, clientPID: clientPID)
            try await self.deliver(text, to: expected.paneID, delivery: .insert)
        }
    }

    /// Checks, as late as possible, that the pane about to be written to is
    /// still the one the user was looking at.
    private func verify(_ expected: DeliveryTarget, nodeID: UUID?, clientPID: Int32?) async throws {
        try requireWritable()
        let server = try await tmux.serverIdentity()
        guard server == expected.server else {
            throw RuntimeError.identityMismatch(detail: "tmux has restarted since then.")
        }
        if let nodeID {
            guard let binding = ledger.binding(nodeID: nodeID) else {
                throw RuntimeError.notBound(nodeID: nodeID)
            }
            guard binding.sessionID == expected.sessionID, binding.paneID == expected.paneID else {
                throw RuntimeError.identityMismatch(detail: "This agent is attached somewhere else now.")
            }
            if let generation = expected.generation, binding.generation != generation {
                throw RuntimeError.identityMismatch(detail: "This agent has been started again since then.")
            }
        }
        let panes = try await tmux.listPanes()
        guard let pane = panes.first(where: { $0.id == expected.paneID }) else {
            throw RuntimeError.identityMismatch(detail: "Pane \(expected.paneID) is gone.")
        }
        guard pane.sessionID == expected.sessionID else {
            throw RuntimeError.identityMismatch(detail: "Pane \(expected.paneID) belongs to \(pane.sessionName) now.")
        }
        guard pane.isActive, pane.isWindowActive else {
            throw RuntimeError.paneNotVisible(sessionName: pane.sessionName)
        }
        try await requireClientIsShowing(
            sessionID: expected.sessionID, paneID: expected.paneID,
            sessionName: pane.sessionName, clientPID: clientPID)
    }

    /// One delivery at a time per pane, so dictation, an image path and a team
    /// update cannot interleave halfway through each other.
    private func withPane<T>(_ paneID: String, _ work: () async throws -> T) async throws -> T {
        while let inFlight = paneDeliveries[paneID] {
            _ = await inFlight.result
        }
        let gate = Task<Void, Never> { }
        paneDeliveries[paneID] = gate
        defer { paneDeliveries[paneID] = nil }
        return try await work()
    }

    /// `fromClient` is the PID of the embedded terminal's tmux client, when the
    /// message is being sent from a terminal the user is looking at.
    public func send(
        _ text: String,
        toNode nodeID: UUID,
        fromClient clientPID: Int32? = nil,
        delivery: Delivery = .submit
    ) async throws {
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
        try await deliver(text, to: binding.paneID, delivery: delivery)
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
        fromClient clientPID: Int32? = nil,
        delivery: Delivery = .submit
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
        try await deliver(text, to: pane.id, delivery: delivery)
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

    /// The text travels as a private buffer, so it is never parsed as a command
    /// by tmux or by a shell. Enter is a separate step, and only for a submit.
    private func deliver(_ text: String, to paneID: String, delivery: Delivery) async throws {
        let bufferName = "marmy-\(makeID().uuidString.lowercased())"
        // Loading the buffer changes nothing in the pane, so a failure here is
        // safe to retry.
        try await tmux.loadBuffer(name: bufferName, text: text)
        do {
            // paste-buffer -d removes the buffer itself on success. The paste
            // inserts at the cursor: whatever the user had typed stays.
            try await tmux.pasteBuffer(name: bufferName, target: paneID)
        } catch {
            try? await tmux.deleteBuffer(name: bufferName)
            // The paste may have gone in before this failed; nobody should
            // repeat a long prompt on a guess.
            throw RuntimeError.deliveryUncertain(detail: "\(error)")
        }
        if delivery == .submit {
            do {
                try await tmux.sendEnter(target: paneID)
            } catch {
                throw RuntimeError.deliveryUncertain(detail: "\(error)")
            }
        }
    }

    /// Sends a message Marmy composed to an agent, writing it down first.
    ///
    /// The journal entry is stored before anything is dispatched: if it cannot
    /// be stored, nothing is sent, because an agent being told something Marmy
    /// has no record of is worse than a message that did not go. "Submitted"
    /// means tmux took it — not that the agent read it, and certainly not that
    /// it agreed.
    @discardableResult
    public func deliverJournaled(
        _ text: String,
        kind: JournalEntry.Kind,
        toNode nodeID: UUID,
        topologyID: UUID?,
        expecting expected: DeliveryTarget,
        delivery: Delivery,
        fromClient clientPID: Int32? = nil
    ) async throws -> JournalEntry {
        let entry = try await recordPrepared(
            text, kind: kind, toNode: nodeID, topologyID: topologyID, expecting: expected)
        return try await sendPrepared(
            entry, expecting: expected, delivery: delivery, fromClient: clientPID)
    }

    /// Writes a message down before anybody tries to send it.
    ///
    /// If it cannot be stored, nothing is sent: an agent being told something
    /// Marmy has no record of is worse than a message that did not go.
    public func recordPrepared(
        _ text: String,
        kind: JournalEntry.Kind,
        toNode nodeID: UUID,
        topologyID: UUID?,
        expecting expected: DeliveryTarget
    ) async throws -> JournalEntry {
        try requireWritable()
        let binding = ledger.binding(nodeID: nodeID)
        let entry = JournalEntry(
            id: makeID(),
            kind: kind,
            status: .prepared,
            createdAt: now(),
            topologyID: topologyID,
            nodeID: nodeID,
            sessionName: binding?.sessionName ?? "",
            sessionID: expected.sessionID,
            paneID: expected.paneID,
            server: expected.server,
            generation: expected.generation,
            payload: text)
        do {
            try await journal.record(entry)
        } catch {
            throw RuntimeError.journalUnavailable(detail: "\(error)")
        }
        return entry
    }

    /// Sends something already written down, and records what became of it.
    ///
    /// The entry is marked as being sent *before* tmux is touched, so a Marmy
    /// that stops halfway leaves an attempt that is uncertain rather than one
    /// that looks untried. "Submitted" means tmux took it — not that the agent
    /// read it, and certainly not that it agreed.
    ///
    /// `requireIdle` is for messages Marmy sends on its own: the agent has to be
    /// at an empty prompt, and that is checked here, inside the pane's queue and
    /// after the identity checks, so nothing can type into the prompt in between.
    @discardableResult
    public func sendPrepared(
        _ entry: JournalEntry,
        expecting expected: DeliveryTarget,
        delivery: Delivery,
        requireIdle: Bool = false,
        in topology: Topology? = nil,
        fromClient clientPID: Int32? = nil
    ) async throws -> JournalEntry {
        try requireWritable()

        do {
            return try await withPane(expected.paneID) {
                // Read again in here. Two callers holding the same entry both
                // reach this point; only one of them finds it still waiting,
                // because the pane's queue lets one in at a time and the status
                // moves off `prepared` before any byte goes out.
                guard let stored = try await self.journal.entry(id: entry.id) else {
                    throw RuntimeError.journalUnavailable(detail: "that message is no longer on record.")
                }
                guard stored.status == .prepared else {
                    throw RuntimeError.journalUnavailable(
                        detail: "that message has already been dealt with (\(stored.status.rawValue)).")
                }
                guard stored.payload == entry.payload, stored.nodeID == entry.nodeID else {
                    throw RuntimeError.journalUnavailable(
                        detail: "that message does not match what was recorded.")
                }
                // What it was recorded for has to be where it is going. A pane
                // that has since been relaunched is a different recipient, and
                // gets a fresh attempt of its own.
                guard stored.matches(expected) else {
                    throw RuntimeError.journalUnavailable(
                        detail: "that message was recorded for a different terminal.")
                }

                if delivery == .insert, let refusal = InsertSafety.refusal(for: stored.payload) {
                    try? await self.journal.update(
                        stored.id, status: .failed, detail: refusal.description, now: self.now())
                    throw RuntimeError.unsafeToInsert(reason: refusal.description)
                }

                do {
                    try await self.verify(expected, nodeID: stored.nodeID, clientPID: clientPID)
                    if requireIdle {
                        // Checked here, holding the pane, so a dictation queued
                        // a moment ago cannot have filled the prompt in between.
                        guard let nodeID = stored.nodeID, let topology else {
                            throw RuntimeError.agentBusy(
                                detail: "Marmy cannot tell what this agent is doing.")
                        }
                        let assessment: AgentReadiness.Assessment
                        do {
                            assessment = try await self.readiness(forNode: nodeID, in: topology)
                        } catch {
                            // Not knowing is not permission. It waits, visibly,
                            // and the user can send it by hand.
                            throw RuntimeError.agentBusy(
                                detail: "Marmy could not tell what this agent is doing: \(error)")
                        }
                        guard assessment.isIdle else {
                            throw RuntimeError.agentBusy(detail: assessment.reason ?? "it is busy.")
                        }
                    }
                    // Recorded as in flight before a single byte goes out.
                    try await self.journal.update(stored.id, status: .sending, now: self.now())
                    try await self.deliver(stored.payload, to: expected.paneID, delivery: delivery)
                } catch let error as RuntimeError {
                    let status: JournalEntry.Status
                    switch error {
                    case .deliveryUncertain: status = .uncertain
                    case .agentBusy: status = .prepared      // still waiting, not failed
                    default: status = .failed
                    }
                    try? await self.journal.update(
                        stored.id, status: status, detail: "\(error)", now: self.now())
                    throw error
                } catch {
                    try? await self.journal.update(
                        stored.id, status: .failed, detail: "\(error)", now: self.now())
                    throw error
                }

                let status: JournalEntry.Status = delivery == .submit ? .submitted : .pasted
                do {
                    return try await self.journal.update(
                        stored.id, status: status, now: self.now()) ?? stored
                } catch {
                    // It went, and the record of it going did not. Saying
                    // "failed" would invite sending it twice. Marmy tries to
                    // write down the uncertainty itself; if the disk will not
                    // take that either, the entry stays `sending`, which says
                    // the same thing: an attempt nobody can account for.
                    try? await self.journal.update(
                        stored.id, status: .uncertain,
                        detail: "It was delivered, but Marmy could not record that: \(error)",
                        now: self.now())
                    throw RuntimeError.deliveryUncertain(
                        detail: "it was delivered but Marmy could not record that: \(error)")
                }
            }
        }
    }

    /// Records a fresh attempt that replaces an earlier one, keeping the old
    /// attempt exactly as it was.
    public func prepareRetry(
        of entry: JournalEntry,
        expecting expected: DeliveryTarget
    ) async throws -> JournalEntry {
        try requireWritable()
        let binding = entry.nodeID.flatMap { ledger.binding(nodeID: $0) }
        let retry = JournalEntry(
            id: makeID(),
            kind: entry.kind,
            status: .prepared,
            createdAt: now(),
            topologyID: entry.topologyID,
            nodeID: entry.nodeID,
            sessionName: binding?.sessionName ?? entry.sessionName,
            sessionID: expected.sessionID,
            paneID: expected.paneID,
            server: expected.server,
            generation: expected.generation,
            payload: entry.payload,
            previousAttemptID: entry.id)
        try await journal.record(retry)
        if entry.status == .prepared {
            try? await journal.update(
                entry.id, status: .superseded,
                detail: "Replaced by a fresh attempt.", now: now())
        }
        return retry
    }

    /// Marks a never-attempted message as replaced by a newer one.
    ///
    /// Only one that was never tried. An attempt that failed, or one nobody can
    /// account for, is history: it stays as it is, and the user decides.
    @discardableResult
    public func supersede(_ entry: JournalEntry, reason: String) async -> Bool {
        guard let stored = try? await journal.entry(id: entry.id), stored.status == .prepared else {
            return false
        }
        return (try? await journal.update(
            entry.id, status: .superseded, detail: reason, now: now())) != nil
    }

    /// Turns anything a previous run left mid-flight into an honest uncertainty.
    @discardableResult
    public func reconcileJournal() async throws -> [JournalEntry] {
        try await journal.reconcileAfterRestart(now: now())
    }

    /// The user throwing away a message that was never sent.
    ///
    /// Only one that was never attempted. What became of an attempt — that it
    /// failed, or that nobody can say whether it arrived — is a fact about the
    /// agent, and dismissing it from the screen does not change it.
    @discardableResult
    public func discard(_ entry: JournalEntry, reason: String) async throws -> Bool {
        guard let stored = try await journal.entry(id: entry.id) else { return false }
        guard stored.status == .prepared else { return false }
        do {
            try await journal.update(entry.id, status: .discarded, detail: reason, now: now())
        } catch {
            throw RuntimeError.journalUnavailable(detail: "\(error)")
        }
        return true
    }

    /// Whether an agent is sitting at an empty prompt, so an automatic message
    /// can go now rather than waiting.
    public func readiness(forNode nodeID: UUID, in topology: Topology) async throws -> AgentReadiness.Assessment {
        let node = topology.node(nodeID)
        guard let binding = ledger.binding(nodeID: nodeID) else {
            throw RuntimeError.notBound(nodeID: nodeID)
        }
        let server = try await tmux.serverIdentity()
        let panes = try await tmux.listPanes()
        let sessions = try await tmux.listSessions()
        let state = LiveIdentity.state(for: binding, server: server, panes: panes, sessions: sessions)
        guard case .running = state, let pane = panes.first(where: { $0.id == binding.paneID }) else {
            return AgentReadiness.Assessment(
                verdict: .notIdle("This agent is not running."), observedCommand: "", cursorLine: "")
        }
        let screen = try await tmux.screen(binding.paneID)
        return AgentReadiness.assess(
            cli: node?.cli ?? binding.cli,
            launchCommand: binding.launchCommand,
            observedCommand: pane.currentCommand,
            screen: screen.lines,
            escapedScreen: screen.escapedLines,
            cursorRow: screen.row,
            cursorColumn: screen.column,
            acceptsMessages: node?.acceptsAgentMessages ?? false)
    }

    /// Scrollback read straight out of tmux, for the app's own history view.
    ///
    /// Reading is always allowed, including in read-only mode: nothing is sent,
    /// no mode is entered, and no other client is disturbed. The pane is checked
    /// against the binding first, so history is never read from whatever else
    /// might be using that id now.
    public func history(forNode nodeID: UUID, maxLines: Int = 5000) async throws -> PaneHistory {
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
        return try await history(paneID: binding.paneID, maxLines: maxLines)
    }

    /// Scrollback for one exact pane, checked the way a send is checked.
    ///
    /// The caller passes the identity that was on screen: the server, the
    /// session, the pane, the launch generation for a team member, and the
    /// embedded client showing it. If any of that has moved on — relaunched,
    /// reconnected, switched to another session inside tmux — the read is
    /// refused rather than returning somebody else's transcript.
    public func history(
        paneID: String,
        sessionID: String,
        onServer expectedServer: TmuxServerIdentity,
        nodeID: UUID? = nil,
        generation: UUID? = nil,
        clientPID: Int32? = nil,
        maxLines: Int = 5000
    ) async throws -> PaneHistory {
        let current = try await tmux.serverIdentity()
        guard current == expectedServer else {
            throw RuntimeError.identityMismatch(detail: "tmux has restarted since this was opened.")
        }
        if let nodeID {
            guard let binding = ledger.binding(nodeID: nodeID) else {
                throw RuntimeError.notBound(nodeID: nodeID)
            }
            guard binding.sessionID == sessionID, binding.paneID == paneID else {
                throw RuntimeError.identityMismatch(detail: "This agent is attached somewhere else now.")
            }
            if let generation, binding.generation != generation {
                throw RuntimeError.identityMismatch(detail: "This agent has been started again since then.")
            }
        }

        let panes = try await tmux.listPanes()
        guard let pane = panes.first(where: { $0.id == paneID }) else {
            throw RuntimeError.identityMismatch(detail: "Pane \(paneID) is gone.")
        }
        guard pane.sessionID == sessionID else {
            throw RuntimeError.identityMismatch(detail: "Pane \(paneID) belongs to \(pane.sessionName) now.")
        }
        guard pane.isActive, pane.isWindowActive else {
            throw RuntimeError.paneNotVisible(sessionName: pane.sessionName)
        }
        try await requireClientIsShowing(
            sessionID: sessionID, paneID: paneID, sessionName: pane.sessionName, clientPID: clientPID)

        return try await history(paneID: paneID, maxLines: maxLines)
    }

    /// Scrollback for a session the user opened directly.
    public func history(
        forSessionID sessionID: String,
        onServer expectedServer: TmuxServerIdentity? = nil,
        maxLines: Int = 5000
    ) async throws -> PaneHistory {
        if let expectedServer {
            let current = try await tmux.serverIdentity()
            guard current == expectedServer else {
                throw RuntimeError.identityMismatch(
                    detail: "tmux has restarted since this session was opened.")
            }
        }
        let panes = try await tmux.listPanes()
        guard let pane = panes.first(where: { $0.sessionID == sessionID && $0.isActive && $0.isWindowActive })
        else {
            throw RuntimeError.identityMismatch(detail: "Session \(sessionID) is no longer showing a pane.")
        }
        return try await history(paneID: pane.id, maxLines: maxLines)
    }

    private func history(paneID: String, maxLines: Int) async throws -> PaneHistory {
        let available = try await tmux.paneHistorySize(paneID)
        let limit = max(0, maxLines)
        let requestedScrollback = min(max(available, 0), limit)
        let text = try await tmux.capturePane(
            paneID, lines: requestedScrollback, joinWrapped: false, includingEscapes: true)
        // What came back is scrollback plus the screen itself, so the honest
        // number is the rows in hand — not what was asked for.
        let capturedLines = text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
        return PaneHistory(
            paneID: paneID,
            text: text,
            scrollbackLines: available,
            capturedLines: capturedLines,
            omittedScrollbackLines: max(0, available - requestedScrollback),
            capturedAt: now())
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

/// A pane's scrollback as it was at one moment.
public struct PaneHistory: Sendable, Equatable {
    public var paneID: String
    /// Raw output including colour escapes; rendered, never executed.
    public var text: String
    /// How many lines tmux is keeping for this pane.
    public var scrollbackLines: Int
    /// Rows actually in this snapshot: scrollback plus the visible screen.
    public var capturedLines: Int
    /// Scrollback older than this snapshot reaches.
    public var omittedScrollbackLines: Int
    public var capturedAt: Date

    public init(
        paneID: String,
        text: String,
        scrollbackLines: Int,
        capturedLines: Int,
        omittedScrollbackLines: Int = 0,
        capturedAt: Date
    ) {
        self.paneID = paneID
        self.text = text
        self.scrollbackLines = scrollbackLines
        self.capturedLines = capturedLines
        self.omittedScrollbackLines = omittedScrollbackLines
        self.capturedAt = capturedAt
    }

    /// True when tmux is holding history this snapshot does not reach.
    public var isTruncated: Bool { omittedScrollbackLines > 0 }
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
