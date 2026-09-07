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
    /// Called after a team's shape changes, so whoever is affected can be told.
    @ObservationIgnored public var onTopologyChanged: ((UUID) -> Void)?
    /// Called when a team has just been started, since its agents were told the
    /// current shape in their own starting prompts.
    /// Called with the agents a launch actually started. Only those were given
    /// a starting prompt, so only those can be assumed to know the team.
    @ObservationIgnored public var onTeamLaunched: ((Topology, Set<UUID>) -> Void)?
    /// Called after each look at the tmux server, so what is running can be
    /// compared with what was running.
    @ObservationIgnored public var onStateObserved: (() -> Void)?
    /// Selection and remembered reports, per team.
    public private(set) var navigation: [UUID: NavigationState] = [:]
    /// Node being edited in the topology inspector.
    public var inspectedNodeID: UUID?
    /// Which teams are open in the sidebar. Every team can be closed at once,
    /// and selecting an agent never forces a team back open.
    public var expandedTopologyIDs: Set<UUID> = []
    public var showsContactConnections = true

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
            // One team open to begin with; after that it is the user's business.
            expandedTopologyIDs = [id]
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

    public func isExpanded(_ topologyID: UUID) -> Bool {
        expandedTopologyIDs.contains(topologyID)
    }

    public func toggleExpansion(_ topologyID: UUID) {
        if expandedTopologyIDs.contains(topologyID) {
            expandedTopologyIDs.remove(topologyID)
        } else {
            expandedTopologyIDs.insert(topologyID)
        }
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

    /// Opens a session the user already had. It gets a terminal and
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

    /// Where the selection is, as a team plus an agent.
    public var selectedLocation: AgentLocation? {
        guard let topologyID = selectedTopologyID, let nodeID = selectedNodeID else { return nil }
        return AgentLocation(topologyID: topologyID, nodeID: nodeID)
    }

    /// Keyboard navigation.
    ///
    /// At the root layer this crosses teams — the orchestrators you are running
    /// are peers of each other. Under a manager it stays among that manager's
    /// reports. Each team keeps its own memory of where you were.
    public func move(_ move: NavigationMove) {
        selectedLocalSession = nil
        let from = selectedLocation
        let remembered = from.flatMap { navigation[$0.topologyID]?.lastVisitedChild } ?? [:]

        guard let destination = WorkspaceNavigator.destination(
            for: move, from: from, in: workspace.topologies, rememberedChildren: remembered)
        else { return }
        guard destination != from else { return }

        select(location: destination, recordingParentOf: from, for: move)
    }

    /// Applies a destination, keeping the per-team memory current.
    private func select(location: AgentLocation, recordingParentOf previous: AgentLocation?, for move: NavigationMove) {
        guard let topology = workspace.topology(location.topologyID) else { return }

        var state = navigation[location.topologyID] ?? NavigationState()
        state.selectedNodeID = location.nodeID
        // Moving up remembers the report you came from.
        if move == .parent, let previous, previous.topologyID == location.topologyID {
            state.lastVisitedChild[location.nodeID] = previous.nodeID
        }
        if let node = topology.node(location.nodeID), let parentID = node.parentID {
            state.lastVisitedChild[parentID] = location.nodeID
        }
        navigation[location.topologyID] = TopologyNavigator.normalized(state, in: topology)

        if selectedTopologyID != location.topologyID {
            selectedTopologyID = location.topologyID
        } else {
            selectionDidChange()
        }
        if mode == .topology { inspectedNodeID = location.nodeID }
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

    /// The agents at the selected one's layer: siblings under its manager, or
    /// every root across every team.
    public func peerLocations(of nodeID: UUID) -> [AgentLocation] {
        guard let topologyID = selectedTopologyID else { return [] }
        return WorkspaceNavigator.peers(
            of: AgentLocation(topologyID: topologyID, nodeID: nodeID),
            in: workspace.topologies)
    }

    public func node(at location: AgentLocation) -> AgentNode? {
        workspace.topology(location.topologyID)?.node(location.nodeID)
    }

    public func teamName(of location: AgentLocation) -> String {
        workspace.topology(location.topologyID)?.name ?? ""
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
        onStateObserved?()
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
        persist(workspace)
    }

    /// Writes a candidate workspace without adopting it.
    ///
    /// Destructive edits use this first: if the write fails, the workspace in
    /// front of the user is still the one on disk, and nothing else — bindings
    /// included — has been touched.
    @discardableResult
    private func persist(_ candidate: Workspace) -> Bool {
        guard loadFailure == nil else {
            banner = .failure(
                "Not saved",
                "The saved workspace could not be read, so Marmy will not write over it. "
                    + "Move or fix the file, then reopen the app.")
            return false
        }
        do {
            try store.save(candidate)
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
        onTopologyChanged?(topology.id)
    }

    public func addTeam(_ topology: Topology) {
        workspace.upsert(topology)
        selectTopology(topology.id)
        save()
    }

    /// Removes a team's organisation only. Sessions keep running and reappear
    /// under local sessions.
    public func deleteSelectedTopology() async {
        guard let id = selectedTopologyID else { return }
        await deleteTopology(id)
    }

    /// Removes one team, whichever is selected.
    ///
    /// The workspace is written before anything else changes: a failed save
    /// leaves the team, its bindings, and the selection exactly as they were.
    /// Deleting a team you are not looking at leaves your selection
    /// alone.
    public func deleteTopology(_ id: UUID) async {
        guard let topology = workspace.topology(id) else { return }
        let wasSelected = (selectedTopologyID == id)

        var candidate = workspace
        candidate.removeTopology(id)
        guard persist(candidate) else { return }
        workspace = candidate

        navigation.removeValue(forKey: id)
        expandedTopologyIDs.remove(id)
        if let inspected = inspectedNodeID, topology.contains(inspected) {
            inspectedNodeID = nil
        }

        if wasSelected {
            // Land on something real rather than an empty header.
            let next = workspace.topologies.first
            if let next, navigation[next.id]?.selectedNodeID == nil,
               let first = next.roots.first ?? next.nodes.first {
                // The selection moves; how the sidebar is arranged is the user's
                // business, so a collapsed team stays collapsed.
                navigation[next.id] = NavigationState(selectedNodeID: first.id)
            }
            // The didSet fires the one selection notification this needs.
            selectedTopologyID = next?.id
        }

        // Only now that the removal is on disk: forgetting a binding for a team
        // that is still saved would strand it.
        var forgetFailures: [String] = []
        for node in topology.nodes {
            do {
                _ = try await runtime.forget(nodeID: node.id)
            } catch {
                forgetFailures.append("\(node.displayName): \(error)")
            }
        }
        await refresh()

        guard forgetFailures.isEmpty else {
            banner = .failure(
                "Removed, but some records were left behind",
                forgetFailures.joined(separator: "\n"))
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

        // Planned, written, and only then applied — so a failed save leaves the
        // agent and its binding exactly as they were.
        topology.remove(nodeID)
        var candidate = workspace
        candidate.upsert(topology)
        guard persist(candidate) else { return }
        workspace = candidate

        if inspectedNodeID == nodeID { inspectedNodeID = nil }
        navigation[topology.id] = TopologyNavigator.normalized(
            navigation[topology.id] ?? NavigationState(), in: topology)
        if selectedTarget != selectionBefore { selectionDidChange() }

        var forgetFailure: String?
        do {
            _ = try await runtime.forget(nodeID: nodeID)
        } catch {
            forgetFailure = "\(error)"
        }
        await refresh()

        if let forgetFailure {
            banner = .failure("Removed, but its record could not be updated", forgetFailure)
            return
        }
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
        // Worker 1, Worker 2, Manager 1 — a name you can tell apart in the
        // sidebar, with a session name to match.
        let displayName = DefaultAgentNaming.nextDisplayName(for: kind, in: topology)
        let directory = topology.nodes.first?.workingDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        var node = AgentNode(
            sessionName: DefaultAgentNaming.sessionName(
                for: displayName, avoiding: allClaimedSessionNames),
            displayName: displayName,
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

    /// Renames an agent.
    ///
    /// One name. What you type is the label, and the tmux session name a future
    /// start will ask for is derived from it — sanitised, and moved out of the
    /// way of every name another agent plans to use or the live server already
    /// has.
    ///
    /// Nothing that is running is touched: no session is renamed, no binding
    /// moves, and an agent that is up keeps the session it is actually in. The
    /// new name is what the *next* start will ask for.
    public func rename(_ nodeID: UUID, to newName: String) {
        guard var topology = workspace.topologies.first(where: { $0.contains(nodeID) }),
              var node = topology.node(nodeID)
        else { return }
        node.displayName = newName

        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            node.sessionName = DefaultAgentNaming.sessionName(
                for: trimmed, avoiding: sessionNamesClaimedByOthers(than: node))
        }
        topology.upsert(node)
        update(topology)
    }

    /// Every session name this node may not take.
    ///
    /// Two exclusions, both narrow. Its own planned name, so retyping the same
    /// thing does not walk the number up on every keystroke. And the live
    /// session it is actually bound to — identified by the binding, not by a
    /// name that happens to match — so an agent may keep asking for the session
    /// it is already in. Another team's identical plan, or an unmanaged session
    /// that happens to share the name, still forces a suffix.
    func sessionNamesClaimedByOthers(than node: AgentNode) -> Set<String> {
        var names: Set<String> = []
        // What every other saved agent plans to use, and any session one of them
        // is attached to.
        for topology in workspace.topologies {
            for other in topology.nodes where other.id != node.id {
                names.insert(other.sessionName)
                if let attached = other.attachedSessionName { names.insert(attached) }
            }
        }
        // Everything alive on the server, except the session this agent is
        // actually bound to — established from the binding, not from a name that
        // happens to match. An unmanaged session with the same name still counts.
        var ownLiveSession: String?
        if case .running(_, let sessionName, _) = state(of: node.id) {
            ownLiveSession = sessionName
        }
        for session in readout.sessions where session.name != ownLiveSession {
            names.insert(session.name)
        }
        return names
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
        if !outcome.started.isEmpty { onTeamLaunched?(topology, Set(outcome.started.keys)) }
        banner = summarize(outcome, in: topology)
    }

    public func startNode(_ nodeID: UUID) async {
        guard requireRuntime(), let topology = selectedTopology else { return }
        isLaunching = true
        defer { isLaunching = false }

        let outcome = await runtime.launch(topology: topology, workspace: workspace, nodeIDs: [nodeID])
        lastPreflight = outcome.preflight
        await refresh()
        // The one that started was just told the team in its own prompt; nobody
        // else was.
        if !outcome.started.isEmpty { onTeamLaunched?(topology, Set(outcome.started.keys)) }
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
        if !outcome.warnings.isEmpty {
            // They are running: this is not a failure. It is something the user
            // would want to know before trusting the message history.
            return Banner(
                kind: .warning,
                title: "Started \(names(outcome.started.keys))",
                detail: outcome.warnings.values.sorted().joined(separator: "\n"))
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

    // MARK: - Templates

    public func upsert(promptTemplate template: PromptTemplate) {
        workspace.upsert(template)
        save()
    }

    /// How many agents across every team use a role prompt.
    ///
    /// What makes a template "shared" is not a flag on it: it is how many agents
    /// would change if you edited it.
    public func agentsUsing(promptTemplate id: UUID) -> [AgentNode] {
        workspace.topologies.flatMap { topology in
            topology.nodes.filter { $0.promptTemplateID == id }
        }
    }

    /// Gives one agent a role prompt of its own, copied from the one it uses.
    ///
    /// The copy is the agent's real role text — the thing that gets rendered
    /// into its starting prompt — not an extra paragraph bolted onto a shared
    /// one. Everyone else keeps the original, untouched.
    ///
    /// Written before it is believed: the copy and the agent's new assignment go
    /// to disk together, and only then does the app adopt them. A failed write
    /// leaves both the library and this agent exactly as they were.
    ///
    /// Returns the new template, or `nil` if there was nothing to copy or the
    /// write failed.
    @discardableResult
    public func customizePromptTemplate(for nodeID: UUID) -> PromptTemplate? {
        guard var topology = workspace.topologies.first(where: { $0.contains(nodeID) }),
              var node = topology.node(nodeID),
              let sourceID = node.promptTemplateID,
              let source = workspace.promptTemplate(sourceID)
        else { return nil }

        let copy = source.duplicated(name: uniqueTemplateName("\(node.displayName)'s role prompt"))
        node.promptTemplateID = copy.id
        topology.upsert(node)

        var candidate = workspace
        candidate.upsert(copy)
        candidate.upsert(topology)
        guard persist(candidate) else { return nil }

        workspace = candidate
        onTopologyChanged?(topology.id)
        return copy
    }

    /// A name no other role prompt has, so the list stays readable.
    func uniqueTemplateName(_ wanted: String) -> String {
        let taken = Set(workspace.promptTemplates.map(\.name))
        guard taken.contains(wanted) else { return wanted }
        var index = 2
        while taken.contains("\(wanted) \(index)") { index += 1 }
        return "\(wanted) \(index)"
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
