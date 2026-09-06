import Foundation
import MarmyCore
import MarmyRuntime
import Observation

/// The app's state: the saved workspace, what is selected, what is live, and
/// every action the UI can take.
///
/// Everything the views touch lives on the main actor; every subprocess goes
/// through the `AgentRuntime` actor, so no view ever waits on tmux.
@MainActor
@Observable
public final class AppModel {

    // MARK: - Stored state

    public private(set) var workspace: Workspace
    /// Set when the saved file could not be read. While this is set nothing is
    /// written, so a bad file is never overwritten with an empty one.
    public private(set) var loadFailure: String?
    public var banner: Banner?

    public var mode: WorkMode = .work {
        didSet { if mode != oldValue { selectionDidChange() } }
    }
    public var selectedTopologyID: UUID? {
        didSet { if selectedTopologyID != oldValue { selectionDidChange() } }
    }
    public private(set) var selectedLocalSession: LocalSessionKey? {
        didSet { if selectedLocalSession != oldValue { selectionDidChange() } }
    }
    /// Called whenever what the work view points at changes, by any route:
    /// clicking, the keyboard, a menu, or a session disappearing underneath us.
    @ObservationIgnored public var onSelectionChanged: (() -> Void)?
    /// Selection and remembered reports, per team.
    public private(set) var navigation: [UUID: NavigationState] = [:]
    /// Node being edited in the topology inspector.
    public var inspectedNodeID: UUID?
    public var showsContactConnections = true

    public let drafts = DraftStore()

    // MARK: - Live state

    public private(set) var readout = RuntimeReadout(server: nil, sessions: [], panes: [], bindings: [])
    public private(set) var runtimeFailure: String?
    public private(set) var isLaunching = false
    public private(set) var lastPreflight: PreflightReport?
    /// Set when the runtime could not be prepared — a ledger that will not load,
    /// or no tmux. Everything that would start, attach, or message an agent is
    /// refused while this is set; the saved teams stay readable and editable.
    public private(set) var startupFailure: String?

    // MARK: - Collaborators

    public let runtime: AgentRuntime
    private let store: WorkspaceStore
    private var refreshTask: Task<Void, Never>?

    public init(store: WorkspaceStore, runtime: AgentRuntime, startupFailure: String? = nil) {
        self.store = store
        self.runtime = runtime
        self.startupFailure = startupFailure
        do {
            workspace = try store.loadOrStarter()
        } catch {
            // Keep the file exactly as it is and say so.
            workspace = Workspace(promptTemplates: DefaultTemplates.promptTemplates())
            loadFailure = "\(error)"
        }
        selectedTopologyID = workspace.topologies.first?.id
        if let id = selectedTopologyID, let first = workspace.topology(id)?.nodes.first {
            navigation[id] = NavigationState(selectedNodeID: first.id)
        }
    }

    // MARK: - Selection

    public var topologies: [Topology] { workspace.topologies }

    public var selectedTopology: Topology? {
        selectedTopologyID.flatMap { workspace.topology($0) }
    }

    public var selectedNodeID: UUID? {
        guard let topologyID = selectedTopologyID else { return nil }
        return navigation[topologyID]?.selectedNodeID
    }

    public var selectedNode: AgentNode? {
        guard let id = selectedNodeID else { return nil }
        return selectedTopology?.node(id)
    }

    /// What the work view is showing: a team member, or a local session opened
    /// straight from the sidebar.
    public var selectedTarget: WorkTarget? {
        if let key = selectedLocalSession { return .localSession(key) }
        if let nodeID = selectedNodeID { return .node(nodeID) }
        return nil
    }

    public func selectTopology(_ topologyID: UUID) {
        selectedLocalSession = nil
        selectedTopologyID = topologyID
        if navigation[topologyID]?.selectedNodeID == nil,
           let first = workspace.topology(topologyID)?.roots.first ?? workspace.topology(topologyID)?.nodes.first {
            navigation[topologyID] = NavigationState(selectedNodeID: first.id)
        }
    }

    public func select(node nodeID: UUID) {
        guard let topology = workspace.topologies.first(where: { $0.contains(nodeID) }) else { return }
        selectedLocalSession = nil
        selectedTopologyID = topology.id
        apply(.select(nodeID), in: topology)
        inspectedNodeID = nodeID
    }

    /// Opens a session the user already had. It gets a terminal, a draft, and
    /// dictation, and it is not added to any team.
    public func select(localSession session: TmuxSession) {
        guard let server = readout.server else {
            banner = .failure("tmux is not running", "There is no session to open.")
            return
        }
        let pane = readout.panes.first { $0.sessionID == session.id && $0.isActive && $0.isWindowActive }
        selectedLocalSession = LocalSessionKey(
            sessionID: session.id, server: server, paneID: pane?.id ?? "")
    }

    /// Keyboard navigation. Selection stays inside the current team, and the
    /// report you last looked at is remembered per manager.
    public func move(_ move: NavigationMove) {
        guard let topology = selectedTopology else { return }
        selectedLocalSession = nil
        apply(move, in: topology)
    }

    func selectionDidChange() {
        onSelectionChanged?()
    }

    private func apply(_ move: NavigationMove, in topology: Topology) {
        let current = navigation[topology.id] ?? NavigationState()
        let updated = TopologyNavigator.apply(move, to: current, in: topology)
        guard updated.selectedNodeID != current.selectedNodeID || navigation[topology.id] == nil else {
            navigation[topology.id] = updated
            return
        }
        navigation[topology.id] = updated
        selectionDidChange()
        if mode == .topology, let selected = updated.selectedNodeID {
            inspectedNodeID = selected
        }
    }

    public func peers(of nodeID: UUID) -> [AgentNode] {
        guard let topology = selectedTopology else { return [] }
        return TopologyNavigator.peers(of: nodeID, in: topology)
    }

    // MARK: - Live state

    /// Sessions on this machine that no saved team is bound to.
    public var unassignedSessions: [TmuxSession] {
        let bound = readout.boundSessionIDs
        return readout.sessions.filter { !bound.contains($0.id) }
    }

    public func state(of nodeID: UUID) -> AgentRuntimeState {
        readout.state(of: nodeID)
    }

    public func connection(for target: WorkTarget) -> TargetConnection {
        switch target {
        case .node(let nodeID):
            return readout.state(of: nodeID).connection
        case .localSession(let key):
            guard key.matches(readout.server) else {
                return .ended(reason: "tmux has restarted since this session was opened.")
            }
            guard let session = readout.sessions.first(where: { $0.id == key.sessionID }) else {
                return .ended(reason: "This session is no longer running.")
            }
            let pane = readout.panes.first { $0.sessionID == key.sessionID && $0.isActive && $0.isWindowActive }
            return .attached(sessionName: session.name, paneID: pane?.id ?? "", adopted: true)
        }
    }

    public func binding(for nodeID: UUID) -> AgentBinding? {
        readout.binding(nodeID: nodeID)
    }

    /// The session a target's terminal should attach to, if it is live.
    public func attachedSession(for target: WorkTarget) -> (id: String, name: String)? {
        switch target {
        case .node(let nodeID):
            guard case .running = readout.state(of: nodeID), let binding = readout.binding(nodeID: nodeID) else {
                return nil
            }
            return (binding.sessionID, binding.sessionName)
        case .localSession(let key):
            guard key.matches(readout.server),
                  let session = readout.sessions.first(where: { $0.id == key.sessionID })
            else { return nil }
            return (session.id, session.name)
        }
    }

    public func refresh() async {
        if let startupFailure {
            runtimeFailure = startupFailure
            return
        }
        do {
            readout = try await runtime.readout()
            runtimeFailure = nil
        } catch {
            runtimeFailure = "\(error)"
        }
        pruneSelection()
    }

    /// Polls tmux while the app is open. Cheap: three short commands.
    public func startRefreshing(every interval: Duration = .seconds(3)) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stopRefreshing() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func pruneSelection() {
        let before = selectedTarget
        defer { if selectedTarget != before { selectionDidChange() } }
        if let key = selectedLocalSession,
           !(key.matches(readout.server) && readout.sessions.contains(where: { $0.id == key.sessionID })) {
            selectedLocalSession = nil
        }
        for (topologyID, state) in navigation {
            guard let topology = workspace.topology(topologyID) else {
                navigation.removeValue(forKey: topologyID)
                continue
            }
            navigation[topologyID] = TopologyNavigator.normalized(state, in: topology)
        }
    }

    // MARK: - Saving

    @discardableResult
    public func save() -> Bool {
        guard loadFailure == nil else {
            banner = .failure(
                "Not saved",
                "The saved workspace could not be read, so Marmy will not write over it. "
                    + "Move or fix the file, then reopen the app.")
            return false
        }
        do {
            try store.save(workspace)
            return true
        } catch {
            banner = .failure("Could not save", "\(error)")
            return false
        }
    }

    public var workspaceFileURL: URL { store.fileURL }

    // MARK: - Team editing

    public func update(_ topology: Topology, save shouldSave: Bool = true) {
        workspace.upsert(topology)
        if shouldSave { save() }
    }

    public func addTeam(_ topology: Topology) {
        workspace.upsert(topology)
        selectTopology(topology.id)
        save()
    }

    /// Removes a team's organisation only. Sessions keep running and reappear
    /// under local sessions.
    public func deleteSelectedTopology() async {
        guard let topology = selectedTopology else { return }
        var forgetFailures: [String] = []
        for node in topology.nodes {
            do {
                _ = try await runtime.forget(nodeID: node.id)
            } catch {
                forgetFailures.append("\(node.displayName): \(error)")
            }
        }
        workspace.removeTopology(topology.id)
        navigation.removeValue(forKey: topology.id)
        selectedTopologyID = workspace.topologies.first?.id
        let saved = save()
        await refresh()

        guard saved, forgetFailures.isEmpty else {
            // save() has already explained a write failure; do not claim success
            // over the top of it.
            if saved {
                banner = .failure(
                    "Removed, but some records were left behind",
                    forgetFailures.joined(separator: "\n"))
            }
            return
        }
        banner = Banner(
            kind: .info,
            title: "Removed “\(topology.name)”",
            detail: "Only the team was removed. Any sessions it started are still running "
                + "and are listed under Local sessions.")
    }

    public func deleteNode(_ nodeID: UUID) async {
        guard var topology = selectedTopology, let node = topology.node(nodeID) else { return }
        let selectionBefore = selectedTarget
        let wasRunning = readout.state(of: nodeID).isRunning
        var forgetFailure: String?
        do {
            _ = try await runtime.forget(nodeID: nodeID)
        } catch {
            forgetFailure = "\(error)"
        }
        topology.remove(nodeID)
        workspace.upsert(topology)
        if inspectedNodeID == nodeID { inspectedNodeID = nil }
        navigation[topology.id] = TopologyNavigator.normalized(
            navigation[topology.id] ?? NavigationState(), in: topology)
        drafts.forget(.node(nodeID))
        if selectedTarget != selectionBefore { selectionDidChange() }
        let saved = save()
        await refresh()

        if let forgetFailure {
            banner = .failure("Removed, but its record could not be updated", forgetFailure)
            return
        }
        guard saved else { return }
        banner = Banner(
            kind: .info,
            title: "Removed \(node.displayName)",
            detail: wasRunning
                ? "Its tmux session \(node.tmuxAddress) is still running and is now listed under Local sessions."
                : "Removed from this team.")
    }

    @discardableResult
    public func addNode(kind: AgentKind, parentID: UUID?) -> AgentNode? {
        guard var topology = selectedTopology else { return nil }
        let base = kind == .manager ? "lead" : "build"
        var allocator = SessionNameAllocator(existingNames: allClaimedSessionNames)
        let directory = topology.nodes.first?.workingDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        var node = AgentNode(
            sessionName: allocator.allocate(base),
            displayName: kind == .manager ? "New manager" : "New worker",
            kind: kind,
            cli: topology.nodes.first?.cli ?? .claude,
            workingDirectory: directory,
            parentID: topology.node(parentID ?? UUID())?.kind == .manager ? parentID : nil)
        // The shipped prompts may have been deleted; use whatever applies.
        node.promptTemplateID = validTemplateID(for: node)
        topology.upsert(node)
        workspace.upsert(topology)
        inspectedNodeID = node.id
        apply(.select(node.id), in: topology)
        save()
        return node
    }

    public var allClaimedSessionNames: Set<String> {
        var names = workspace.claimedSessionNames
        names.formUnion(readout.sessions.map(\.name))
        return names
    }

    /// Changes an agent between manager and worker.
    ///
    /// A manager with reports cannot simply become a worker: its reports would be
    /// left reporting to someone who cannot take reports, so the change is
    /// refused and the user is told to move them first.
    public func changeKind(of nodeID: UUID, to kind: AgentKind) {
        guard var topology = selectedTopology, var node = topology.node(nodeID), node.kind != kind else { return }
        let reports = topology.children(of: nodeID)
        if kind == .worker, !reports.isEmpty {
            banner = .failure(
                "\(node.displayName) still has reports",
                "Move \(reports.map(\.displayName).joined(separator: ", ")) to another manager first, "
                    + "then change this agent to a worker.")
            return
        }
        node.kind = kind
        node.promptTemplateID = validTemplateID(for: node)
        topology.upsert(node)
        workspace.upsert(topology)
        save()
    }

    /// Keeps a custom role prompt when it still applies, and otherwise picks a
    /// shipped one that does — or none, if the user deleted them all.
    public func validTemplateID(for node: AgentNode) -> UUID? {
        if let current = node.promptTemplateID,
           let template = workspace.promptTemplate(current),
           template.applicability.matches(node.kind) {
            return current
        }
        let preferred = node.kind == .manager
            ? DefaultTemplates.ID.managerPrompt
            : DefaultTemplates.ID.workerPrompt
        if let shipped = workspace.promptTemplate(preferred), shipped.applicability.matches(node.kind) {
            return shipped.id
        }
        return workspace.promptTemplates.first { $0.applicability.matches(node.kind) }?.id
    }

    /// Moves a node under a new manager, refusing anything that would make a loop.
    @discardableResult
    public func reparent(_ nodeID: UUID, to parentID: UUID?) -> Bool {
        guard var topology = selectedTopology else { return false }
        do {
            try topology.reparent(nodeID, to: parentID)
            workspace.upsert(topology)
            save()
            return true
        } catch let error as TopologyMutationError {
            banner = .failure("Cannot make that connection", describe(error, in: topology))
            return false
        } catch {
            banner = .failure("Cannot make that connection", "\(error)")
            return false
        }
    }

    private func describe(_ error: TopologyMutationError, in topology: Topology) -> String {
        switch error {
        case .selfParent:
            return "An agent cannot report to itself."
        case .cycle(let childID, let parentID):
            let child = topology.node(childID)?.displayName ?? "That agent"
            let parent = topology.node(parentID)?.displayName ?? "the target"
            return "\(parent) already reports to \(child), directly or through someone else. "
                + "Reporting has to flow one way."
        case .parentIsNotManager(let parentID):
            let parent = topology.node(parentID)?.displayName ?? "That agent"
            return "\(parent) is a worker. Only managers can take reports — change its kind first."
        case .unknownNode, .unknownParent:
            return "That agent is no longer part of this team."
        }
    }

    // MARK: - Launching

    /// True when the runtime is usable. Otherwise it explains why not.
    @discardableResult
    public func requireRuntime() -> Bool {
        guard let startupFailure else { return true }
        banner = .failure("Marmy cannot control tmux right now", startupFailure)
        return false
    }

    public func preflightSelectedTeam() async {
        guard requireRuntime(), let topology = selectedTopology else { return }
        lastPreflight = await runtime.preflight(topology: topology, workspace: workspace)
    }

    /// Starts every agent in the selected team that is not already running.
    public func launchSelectedTeam() async {
        guard requireRuntime(), let topology = selectedTopology else { return }
        isLaunching = true
        defer { isLaunching = false }

        let outcome = await runtime.launch(topology: topology, workspace: workspace)
        lastPreflight = outcome.preflight
        await refresh()
        banner = summarize(outcome, in: topology)
    }

    public func startNode(_ nodeID: UUID) async {
        guard requireRuntime(), let topology = selectedTopology else { return }
        isLaunching = true
        defer { isLaunching = false }

        let outcome = await runtime.launch(topology: topology, workspace: workspace, nodeIDs: [nodeID])
        lastPreflight = outcome.preflight
        await refresh()
        banner = summarize(outcome, in: topology)
    }

    private func summarize(_ outcome: LaunchOutcome, in topology: Topology) -> Banner {
        func names(_ ids: some Collection<UUID>) -> String {
            ids.compactMap { topology.node($0)?.displayName }.sorted().joined(separator: ", ")
        }

        if outcome.preflight.isBlocked {
            return Banner(
                kind: .failure,
                title: "Nothing was started",
                detail: outcome.preflight.errors.map(\.message).joined(separator: "\n"))
        }
        if !outcome.failures.isEmpty {
            let failed = outcome.failures
                .compactMap { id, reason in "\(topology.node(id)?.displayName ?? "An agent"): \(reason)" }
                .sorted()
                .joined(separator: "\n")
            let startedNote = outcome.started.isEmpty ? "" : "Started \(names(outcome.started.keys)). "
            return Banner(
                kind: .warning,
                title: "Started with problems",
                detail: startedNote + "Try again to start only what is missing.\n" + failed)
        }
        if outcome.started.isEmpty {
            let skipped = outcome.skipped.isEmpty
                ? "Everything in this team is already running."
                : outcome.skipped.map { id, reason in "\(topology.node(id)?.displayName ?? "An agent") — \(reason)" }
                    .sorted().joined(separator: "\n")
            return Banner(kind: .info, title: "Nothing to start", detail: skipped)
        }
        return Banner(
            kind: .success,
            title: "Started \(names(outcome.started.keys))",
            detail: "Sessions are running. Each agent still has to finish starting up on its own.")
    }

    /// Attaches an existing session to a node because the user asked to. No
    /// prompt or keystroke is sent to it.
    public func adopt(sessionID: String, into nodeID: UUID) async {
        guard requireRuntime(),
              let topology = selectedTopology,
              let session = readout.sessions.first(where: { $0.id == sessionID }),
              let node = topology.node(nodeID)
        else { return }
        do {
            _ = try await runtime.adopt(
                sessionName: session.name, nodeID: nodeID, topology: topology, cli: node.cli)
            await refresh()
            banner = Banner(
                kind: .success,
                title: "Attached \(session.name) to \(node.displayName)",
                detail: "Nothing was sent to it. Its role prompt applies to future launches only.")
        } catch {
            banner = .failure("Could not attach that session", "\(error)")
        }
    }

    // MARK: - Sending

    /// Sends the visible draft to the target it was written for.
    ///
    /// The target is captured before the work starts, so changing selection
    /// mid-send can never redirect the message, and the draft is cleared only if
    /// it still holds exactly what was sent.
    @discardableResult
    public func sendDraft(from target: WorkTarget, clientPID: Int32? = nil) async -> Bool {
        // Captured before any awaiting: what is on screen may change while the
        // send is in flight, and only this exact text may be cleared.
        let draft = drafts.text(for: target)
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard requireRuntime() else { return false }
        do {
            switch target {
            case .node(let nodeID):
                try await runtime.send(draft, toNode: nodeID, fromClient: clientPID)
            case .localSession(let key):
                try await runtime.send(
                    draft,
                    toSessionID: key.sessionID,
                    onServer: key.server,
                    expectedPaneID: key.paneID.isEmpty ? nil : key.paneID,
                    fromClient: clientPID)
            }
            // Anything typed while the message was on its way is kept.
            drafts.clearIfUnchanged(draft, for: target)
            return true
        } catch {
            // The draft stays exactly as it is so nothing is lost.
            banner = .failure("Message not sent", "\(error)")
            return false
        }
    }

    // MARK: - Templates

    public func upsert(promptTemplate template: PromptTemplate) {
        workspace.upsert(template)
        save()
    }

    public func deletePromptTemplate(_ id: UUID) {
        workspace.removePromptTemplate(id)
        save()
    }

    public func upsert(topologyTemplate template: TopologyTemplate) {
        workspace.upsert(template)
        save()
    }

    public func deleteTopologyTemplate(_ id: UUID) {
        workspace.removeTopologyTemplate(id)
        save()
    }

    /// Saves the selected team's shape for reuse.
    public func saveSelectedTeamAsTemplate(named name: String) {
        guard let topology = selectedTopology else { return }
        workspace.upsert(TopologyTemplate(capturing: topology, name: name))
        // Only claim it was saved if it actually reached disk.
        if save() {
            banner = .success("Saved “\(name)” as a team template")
        }
    }

    /// Stamps out a saved shape with fresh identities and free session names.
    @discardableResult
    public func instantiate(templateID: UUID, named name: String?, directory: String?) -> Topology? {
        guard let template = workspace.topologyTemplate(templateID) else { return nil }
        var topology = template.instantiate(
            name: name ?? template.name,
            existingSessionNames: allClaimedSessionNames)
        if let directory {
            for index in topology.nodes.indices {
                topology.nodes[index].workingDirectory = directory
            }
        }
        addTeam(topology)
        return topology
    }

    /// The prompt an agent would be started with right now.
    public func renderedPrompt(for node: AgentNode) -> Result<String, Error> {
        guard let topology = workspace.topologies.first(where: { $0.contains(node.id) }) else {
            return .success("")
        }
        do {
            return .success(try BootstrapPrompt.render(
                for: node, in: topology, workspace: workspace,
                server: runtime.tmux.server,
                resolvedSessionNames: resolvedSessionNames(in: topology)))
        } catch {
            return .failure(error)
        }
    }

    /// Where each agent in a team is addressable right now — the live name for
    /// anything running, the planned one otherwise.
    public func resolvedSessionNames(in topology: Topology) -> [UUID: String] {
        LaunchPreflight.resolvedSessionNames(
            topology: topology,
            states: Dictionary(uniqueKeysWithValues: topology.nodes.map { ($0.id, readout.state(of: $0.id)) }))
    }

    /// Renders one role prompt for a specific agent, exactly as a launch would,
    /// for the template editor's preview.
    public func previewPrompt(template: PromptTemplate, for node: AgentNode) -> Result<String, Error> {
        guard let topology = workspace.topologies.first(where: { $0.contains(node.id) }) else {
            return .success("")
        }
        var resolved = node
        if let live = resolvedSessionNames(in: topology)[node.id], live != node.sessionName {
            resolved.attachedSessionName = live
        }
        var resolvedTopology = topology
        let names = resolvedSessionNames(in: topology)
        resolvedTopology.nodes = topology.nodes.map { candidate in
            var copy = candidate
            if let live = names[candidate.id] {
                copy.attachedSessionName = live == candidate.sessionName ? nil : live
            }
            return copy
        }
        do {
            return .success(try PromptRenderer.render(
                template: template, for: resolved, in: resolvedTopology,
                operatorName: workspace.operatorName))
        } catch {
            return .failure(error)
        }
    }

    /// The agent a role prompt should be previewed against: one it actually
    /// applies to, preferring whatever is selected.
    public func previewSubject(for template: PromptTemplate) -> AgentNode? {
        guard let topology = selectedTopology else { return nil }
        if let selected = selectedNode, template.applicability.matches(selected.kind) { return selected }
        return topology.nodes.first { template.applicability.matches($0.kind) } ?? topology.nodes.first
    }

    public func validationIssues(for topology: Topology) -> [ValidationIssue] {
        TopologyValidator.validate(topology, promptTemplates: workspace.promptTemplates)
    }
}
