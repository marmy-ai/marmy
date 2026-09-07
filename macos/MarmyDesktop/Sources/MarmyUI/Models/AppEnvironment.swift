import AppKit
import Foundation
import MarmyCore
import MarmyRuntime
import Observation
import SwiftTerm

/// Ties the state, the terminals, dictation, and the keyboard together.
///
/// Views talk to this; it owns the rules that cross those pieces — such as
/// stopping a dictation the moment the selection moves, so a transcript can
/// never land on the wrong agent.
@MainActor
@Observable
public final class AppEnvironment {
    public let model: AppModel
    public let terminals = TerminalController()
    public let voice: VoiceController
    public let keyboard = KeyboardCoordinator()
    /// Where images pasted into a terminal are kept.
    public var attachments = AttachmentStore.default()
    /// Tells managers when their team changes.
    public let roster = RosterCoordinator()
    /// A role template the user asked to edit directly, opened when the
    /// templates sheet appears.
    public var templateToEdit: UUID?
    /// What each agent has actually been told, as the journal has it.
    public private(set) var messages: [UUID: [JournalEntry]] = [:]
    /// Bumped whenever the journal changes, so an open history refreshes itself
    /// without the user having to move away and back.
    public private(set) var journalRevision = 0
    /// The agent whose message history is open, if any.
    public var messagesForNode: UUID?
    /// A received file that could not be handed to a prompt. It is still on
    /// disk, and its path can be copied.
    public var recoveredAttachmentPath: String?
    /// Where "Copy path" writes. A test can hand in its own so a run never
    /// disturbs the user's clipboard.
    @ObservationIgnored public var attachmentPasteboard: NSPasteboard = .general
    /// Dictated words waiting to reach a prompt.
    public let dictation = DictationDeliveryQueue()
    private let scrollMonitor = TerminalScrollMonitor()

    /// The terminal for whatever is selected, once it is attached.
    public private(set) var currentPane: TerminalPane?
    /// Set while a sheet is up: shortcuts and hold-to-talk stand down.
    public var isModalPresented = false
    public var showsShortcuts = false
    public var showsNewTeamSheet = false
    public var showsTemplates = false
    public var showsAttachSheet = false
    public var showsSaveTemplateSheet = false
    /// Bumped by the Fit button; the canvas watches it.
    public var fitCanvasToken = 0
    /// A team the user has asked to delete, waiting on the confirmation.
    public var teamPendingDeletion: Topology?
    /// What a confirmation on screen is about, decided when it was asked.
    public var pendingTermination: SessionTerminationPlan?
    /// Briefly shown after keyboard navigation, then fades.
    public private(set) var locationHintToken = 0

    @ObservationIgnored private var hintTask: Task<Void, Never>?
    /// Where each capture was spoken, by capture id. A new hold never disturbs
    /// an older capture's origin.
    @ObservationIgnored private var dictationOrigins: [UUID: DictationOrigin] = [:]
    @ObservationIgnored private var inFlightPastes: Set<UUID> = []
    /// Wheel lines waiting to be sent, and who is sending them.
    @ObservationIgnored private(set) var scrollDrain: ScrollDrain?
    @ObservationIgnored private var nextScrollToken = 0

    /// One run of the coalescing loop.
    ///
    /// The token is what makes it its own: a drain only ever reads or clears the
    /// one it started. Reconnecting to the same terminal, or an error arriving
    /// late from a drain that has been retired, then cannot touch the gestures
    /// somebody is making now.
    struct ScrollDrain {
        var token: Int
        var identity: TerminalIdentity
        var target: WorkTarget
        var clientPID: Int32?
        var lines: Int
    }

    struct DictationOrigin {
        var target: WorkTarget
        var identity: TerminalIdentity
        var clientPID: Int32?
    }
    @ObservationIgnored private var focusObservers: [Any] = []

    public init(model: AppModel, speechEngine: any SpeechEngine) {
        self.model = model
        self.voice = VoiceController(engine: speechEngine)
        configureKeyboard()
        // Every route into a different agent ends up here: clicks, keyboard,
        // menus, and a session vanishing during a refresh.
        model.onSelectionChanged = { [weak self] in
            self?.selectionChanged()
        }
        configureScrolling()
        roster.attach(model: model)
        roster.onJournalChanged = { [weak self] nodeID in
            guard let self else { return }
            self.journalRevision &+= 1
            Task { await self.loadMessages(for: nodeID) }
        }
        // A team edit is announced once things settle, not on every keystroke.
        model.onTopologyChanged = { [weak self] topologyID in
            self?.roster.teamChanged(topologyID)
        }
        model.onTeamLaunched = { [weak self] topology, started in
            // The starting prompts of the agents that were started already
            // describe the team as it is now. Nobody else was told anything.
            self?.roster.adoptBaseline(topology, nodeIDs: started)
        }
        // Availability is noticed by watching what is actually running, so an
        // agent that comes up, moves, or is adopted is announced the same way.
        model.onStateObserved = { [weak self] in
            guard let self else { return }
            Task { await self.roster.observeState() }
        }
        // What was spoken belongs to the capture it came from, and to the agent
        // that capture was spoken to.
        voice.onFinished = { [weak self] captureID, target, text, completion in
            guard let self else { return }
            // Looked up by the capture's own id: a newer hold cannot change
            // where these words were spoken.
            let origin = self.dictationOrigins.removeValue(forKey: captureID)
            let identity = origin?.identity ?? self.unknownIdentity(for: target)

            switch completion {
            case .deliver:
                self.dictation.hold(PendingDictation(
                    id: captureID, target: target, text: text, identity: identity,
                    clientPID: origin?.clientPID, state: .pasting, spokenAt: Date()))
                Task { await self.deliverDictation(captureID) }
            case .retain(let reason):
                // Kept for the agent it was spoken to, and never pasted into
                // whatever the user moved on to.
                self.dictation.hold(PendingDictation(
                    id: captureID, target: target, text: text, identity: identity,
                    clientPID: origin?.clientPID, state: .failed(reason), spokenAt: Date()))
            }
        }
    }

    public convenience init(model: AppModel) {
        self.init(model: model, speechEngine: SpeechEngineFactory.makeEngine())
    }

    // MARK: - Keyboard

    private func configureKeyboard() {
        keyboard.context = { [weak self] in
            guard let self else { return KeyboardCoordinator.Context() }
            return KeyboardCoordinator.Context(
                isWorkMode: self.model.mode == .work,
                terminalHasFocus: self.terminalHasFocus,
                isEditingText: self.isEditingText,
                // A confirmation dialog is not an attached sheet, but it is
                // just as modal: no shortcut may act on the agent behind it.
                isModalPresented: self.isModalPresented
                    || self.teamPendingDeletion != nil
                    || self.pendingTermination != nil
                    || NSApp.keyWindow?.attachedSheet != nil)
        }
        keyboard.onNavigate = { [weak self] direction in
            self?.navigate(direction)
        }
        keyboard.onHoldBegan = { [weak self] in
            self?.beginDictation()
        }
        keyboard.onHoldEnded = { [weak self] in
            self?.voice.endHold()
        }
        // Escape belongs to the terminal: tmux uses it to leave its own
        // scrollback, and agents use it too.
        keyboard.onEscape = { false }
        keyboard.onSpaceTap = { [weak self] in
            // A tap is an ordinary space and belongs to the terminal.
            guard let view = self?.currentPane?.view else { return }
            view.send(source: view, data: ArraySlice([UInt8(ascii: " ")]))
        }
    }

    /// The wheel over the terminal scrolls that terminal's own tmux scrollback.
    ///
    /// The event is taken rather than forwarded: left alone, a tmux client on
    /// the alternate screen turns a wheel gesture into arrow keys and walks the
    /// agent's prompt history. What replaces it is tmux's own scrolling, in the
    /// same pane, at the same size and font — and scrolling back down to the
    /// bottom returns to live output by itself.
    private func configureScrolling() {
        scrollMonitor.terminalView = { [weak self] in self?.currentPane?.view }
        scrollMonitor.shouldReportScroll = { [weak self] in
            guard let self else { return false }
            return !self.isModalPresented && self.teamPendingDeletion == nil
        }
        scrollMonitor.onScrollLines = { [weak self] lines in
            self?.scrollTerminal(lines: lines)
        }
    }

    /// Adds a wheel gesture to what is already on its way.
    ///
    /// A trackpad sends dozens of small events a second and each one is a
    /// process. They are added up while a request is in flight and sent as one,
    /// and the whole drain is retired the moment the terminal changes — a
    /// backlog must never land on a pane it was not meant for.
    func scrollTerminal(lines: Int) {
        guard let target = model.selectedTarget,
              let identity = terminalIdentity(for: target),
              let pane = currentPane,
              pane.identity == identity
        else { return }

        if scrollDrain?.identity == identity {
            scrollDrain?.lines += lines
            return
        }

        nextScrollToken += 1
        let token = nextScrollToken
        scrollDrain = ScrollDrain(
            token: token, identity: identity, target: target,
            clientPID: pane.clientPID == 0 ? nil : pane.clientPID,
            lines: lines)

        Task { [weak self] in
            guard let self else { return }
            while let drain = self.scrollDrain, drain.token == token, drain.lines != 0 {
                self.scrollDrain?.lines = 0
                await self.sendScroll(drain)
            }
            // Only ever its own: a newer drain has its own token and its own
            // terminal, and this one is finished with.
            self.clearScrollDrain(ifToken: token)
        }
    }

    private func sendScroll(_ drain: ScrollDrain) async {
        let expected = AgentRuntime.DeliveryTarget(
            sessionID: drain.identity.sessionID,
            paneID: drain.identity.paneID,
            server: drain.identity.server,
            generation: UUID(uuidString: drain.identity.generation))
        var nodeID: UUID?
        if case .node(let id) = drain.target { nodeID = id }
        do {
            try await model.runtime.scroll(
                lines: drain.lines, in: expected, nodeID: nodeID, fromClient: drain.clientPID)
        } catch {
            // A terminal that has moved on is not worth a banner: the gesture
            // simply does not apply to it any more. Only this drain stops.
            clearScrollDrain(ifToken: drain.token)
        }
    }

    /// Ends the current run of wheel gestures, so nothing left over from it can
    /// reach whatever the terminal is showing next.
    func retireScrollDrain() {
        scrollDrain = nil
    }

    /// Clears the drain only if it is still the one that asked. A late error
    /// from a retired drain must not throw away gestures being made now.
    func clearScrollDrain(ifToken token: Int) {
        if scrollDrain?.token == token { scrollDrain = nil }
    }

    public var terminalHasFocus: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is TerminalView
    }

    public var isEditingText: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if responder is TerminalView { return false }
        if let text = responder as? NSTextView { return text.isEditable }
        return responder is NSTextField
    }

    public func startMonitoring() {
        // Anything a previous run left waiting is picked back up, and anything
        // caught mid-send becomes an honest uncertainty.
        Task { await roster.restorePending() }
        keyboard.install()
        scrollMonitor.install()
        model.startRefreshing()
        let center = NotificationCenter.default
        focusObservers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { self.stopCapture(reason: nil) }
        })
        focusObservers.append(center.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { self.stopCapture(reason: nil) }
        })
        focusObservers.append(center.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { self.shutDown() }
        })
    }

    public func shutDown() {
        stopCapture(reason: nil)
        keyboard.uninstall()
        scrollMonitor.uninstall()
        model.stopRefreshing()
        // Ends our tmux clients only. Every agent keeps running.
        terminals.releaseAll()
        for observer in focusObservers { NotificationCenter.default.removeObserver(observer) }
        focusObservers.removeAll()
    }

    public func stopCapture(reason: String?) {
        // The controller first: `cancelHold` looks exactly like the user letting
        // go, and a release means "put these words in the prompt". A context
        // change means the opposite — keep them where they were spoken.
        voice.cancel(reason: reason)
        keyboard.cancelHold(notifyRelease: false)
    }

    // MARK: - Navigation

    public func navigate(_ direction: KeyboardCoordinator.Navigation) {
        let before = model.selectedTarget
        switch direction {
        case .nextPeer: model.move(.nextPeer)
        case .previousPeer: model.move(.previousPeer)
        case .parent: model.move(.parent)
        case .child: model.move(.child)
        }
        if model.selectedTarget != before {
            showLocationHint()
            // Keyboard navigation should leave the keyboard where the user is
            // looking: in the newly selected agent's terminal.
            syncTerminal()
            focusTerminal()
        }
    }

    // The model tells us when the selection really changed, by whatever route.
    // Clicking the row that is already selected changes nothing, and must not
    // pull the terminal out from under it.
    public func select(node nodeID: UUID) {
        model.select(node: nodeID)
    }

    public func select(localSession session: TmuxSession) {
        model.select(localSession: session)
    }

    public func selectTopology(_ id: UUID) {
        model.selectTopology(id)
    }

    /// Anything that moves the selection ends a capture in flight: a transcript
    /// belongs to the agent it was spoken for.
    public func targetChanged() {
        selectionChanged()
    }

    private func selectionChanged() {
        // Any real move — another agent, another mode, a deleted node — ends a
        // capture. Dictation only makes sense while you are looking at the agent
        // you are talking to.
        stopCapture(reason: nil)
        // A wheel gesture belongs to the terminal it was made over, and that is
        // not this one any more.
        retireScrollDrain()
        currentPane = nil
    }

    /// Asks for confirmation before removing a team.
    ///
    /// The sessions are named now, while the user is looking at them: what is
    /// running can change while a dialog is up, and a confirmation has to be
    /// about what was asked.
    ///
    /// Recording stops as the question goes up: the agent being dictated to may
    /// be one of the ones about to disappear, and a confirmation is a modal
    /// moment either way.
    public func requestDeletion(of topology: Topology) {
        stopCapture(reason: nil)
        teamPendingDeletion = topology
        pendingTermination = SessionTerminationPlan(
            subject: .team(topology), sessions: runningSessions(of: topology))
    }

    /// The sessions a team's agents are actually running in, with who else is in
    /// them.
    private func runningSessions(of topology: Topology) -> [SessionTerminationPlan.Session] {
        guard let server = model.readout.server else { return [] }
        var found: [String: SessionTerminationPlan.Session] = [:]
        for node in topology.nodes {
            // Bound and still alive is the test, not "has a pane on screen": an
            // agent whose pane was closed leaves the session running, and that
            // is exactly the leftover the user is trying to get rid of.
            guard let binding = model.binding(for: node.id),
                  binding.server == server,
                  let live = model.readout.sessions.first(where: { $0.id == binding.sessionID })
            else { continue }
            var session = found[binding.sessionID] ?? SessionTerminationPlan.Session(
                id: binding.sessionID, name: live.name, server: server,
                isAdopted: binding.ownership == .adopted)
            session.agents.append(node.displayName)
            found[binding.sessionID] = session
        }
        // Anyone else in those sessions has to be named: stopping one would stop
        // them, and they are not part of what is being deleted.
        for other in model.workspace.topologies where other.id != topology.id {
            for node in other.nodes {
                guard let binding = model.binding(for: node.id),
                      binding.server == server,
                      var session = found[binding.sessionID]
                else { continue }
                session.otherTeams.append("\(node.displayName) (\(other.name))")
                found[binding.sessionID] = session
            }
        }
        return found.values.sorted { $0.name < $1.name }
    }

    /// Asks for confirmation before stopping one session the user picked.
    /// `server` is the one the row was drawn from, passed in with it: a refresh
    /// between drawing the row and clicking it would otherwise pair an old
    /// session with a new server, which are not the same session at all.
    public func requestTermination(of session: TmuxSession, on server: TmuxServerIdentity) {
        guard model.readout.server == server,
              model.readout.sessions.contains(where: { $0.id == session.id })
        else { return }
        stopCapture(reason: nil)
        var entry = SessionTerminationPlan.Session(
            id: session.id, name: session.name, server: server)
        for topology in model.workspace.topologies {
            for node in topology.nodes {
                guard let binding = model.binding(for: node.id),
                      binding.server == server, binding.sessionID == session.id
                else { continue }
                entry.otherTeams.append("\(node.displayName) (\(topology.name))")
            }
        }
        pendingTermination = SessionTerminationPlan(subject: .session, sessions: [entry])
    }

    /// Removes the team the user confirmed, and stops its sessions if that is
    /// what they chose.
    ///
    /// The plan comes from the button that was pressed, not from what is on
    /// screen now: SwiftUI clears the presentation binding before the action's
    /// task runs, and the selection may have moved anyway.
    public func confirmDeletion(_ plan: SessionTerminationPlan, terminating: Bool) async {
        teamPendingDeletion = nil
        pendingTermination = nil
        stopCapture(reason: nil)

        var outcome = SessionTerminationOutcome()
        if terminating {
            outcome = await terminate(plan.sessions)
        }
        // A team whose sessions could not be stopped keeps its bookkeeping: the
        // user asked for both, and half of it is not what they asked for.
        if let topology = plan.topology {
            guard outcome.isCompleteSuccess else {
                report(outcome, plan: plan, terminated: terminating)
                return
            }
            await model.deleteTopology(topology.id)
            // Removing the team can go wrong on its own — the workspace not
            // saving, its bindings not being let go — and it says so. That
            // message is the important one and is not written over with good
            // news about the sessions.
            if model.banner?.kind == .failure { return }
        }
        report(outcome, plan: plan, terminated: terminating)
    }

    /// Stops the sessions the user picked, and says what actually happened.
    public func confirmTermination(_ plan: SessionTerminationPlan) async {
        pendingTermination = nil
        let outcome = await terminate(plan.sessions)
        report(outcome, plan: plan, terminated: true)
    }

    private func terminate(
        _ sessions: [SessionTerminationPlan.Session]
    ) async -> SessionTerminationOutcome {
        var outcome = SessionTerminationOutcome()
        for session in sessions {
            switch await model.runtime.terminate(sessionID: session.id, on: session.server) {
            case .stopped:
                outcome.stopped.append(session.name)
            case .alreadyGone:
                outcome.alreadyGone.append(session.name)
            case .failed(let reason):
                outcome.failed.append((name: session.name, reason: reason))
            }
        }
        // What is attached, bound and on screen all follow from what is
        // running: a refresh drops a selection whose session has gone.
        await model.refresh()
        syncTerminal()
        return outcome
    }

    private func report(
        _ outcome: SessionTerminationOutcome, plan: SessionTerminationPlan, terminated: Bool
    ) {
        guard terminated else {
            if plan.topology != nil { return }   // the team banner says its own piece
            return
        }
        if outcome.isCompleteSuccess {
            var detail = outcome.stopped.isEmpty ? "" : "Stopped \(outcome.stopped.joined(separator: ", ")). "
            if !outcome.alreadyGone.isEmpty {
                detail += "\(outcome.alreadyGone.joined(separator: ", ")) had already ended."
            }
            model.banner = Banner(
                kind: .success, title: "Sessions stopped",
                detail: detail.isEmpty ? nil : detail)
            return
        }
        let failures = outcome.failed
            .map { "\($0.name): \($0.reason)" }
            .joined(separator: "\n")
        let kept = plan.topology != nil
            ? "\n\nThe team has been left as it is, so you can try again."
            : ""
        model.banner = .failure(
            "Some sessions are still running",
            (outcome.stopped.isEmpty ? "" : "Stopped \(outcome.stopped.joined(separator: ", ")).\n")
                + failures + kept)
    }

    /// Cancelling changes nothing at all.
    public func cancelDeletion() {
        teamPendingDeletion = nil
        pendingTermination = nil
    }

    public func showLocationHint() {
        locationHintToken += 1
        let token = locationHintToken
        hintTask?.cancel()
        hintTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.4))
            guard let self, self.locationHintToken == token else { return }
            self.locationHintToken = 0
        }
    }

    public var showsLocationHint: Bool { locationHintToken > 0 }

    // MARK: - Terminals

    /// The live identity of a target, or nil when nothing is attached to it.
    public func terminalIdentity(for target: WorkTarget) -> TerminalIdentity? {
        guard let server = model.readout.server else { return nil }
        switch target {
        case .node(let nodeID):
            guard case .running(let paneID, _, _) = model.readout.state(of: nodeID),
                  let binding = model.readout.binding(nodeID: nodeID)
            else { return nil }
            return TerminalIdentity(
                target: target, server: server, sessionID: binding.sessionID,
                paneID: paneID, generation: binding.generation.uuidString)
        case .localSession(let key):
            guard key.matches(server),
                  let pane = model.readout.panes.first(where: {
                      $0.sessionID == key.sessionID && $0.isActive && $0.isWindowActive
                  })
            else { return nil }
            return TerminalIdentity(
                target: target, server: server, sessionID: key.sessionID, paneID: pane.id)
        }
    }

    /// Attaches a terminal to whatever is selected, if it is running.
    public func syncTerminal() {
        guard let target = model.selectedTarget,
              let identity = terminalIdentity(for: target),
              let session = model.attachedSession(for: target)
        else {
            currentPane = nil
            return
        }
        if let pane = currentPane, pane.key == identity.key { return }
        // The terminal underneath is changing: nothing queued for the old one
        // may reach the new one, even when it is the same agent reconnecting.
        retireScrollDrain()
        let pane = terminals.pane(
            for: identity,
            sessionName: session.name,
            attachment: model.runtime.tmux.attachment(sessionID: identity.sessionID))
        configureAttachments(on: pane, identity: identity, target: target)
        currentPane = pane
    }

    /// Pasted and dropped files go into the prompt through the same door as
    /// everything else Marmy types: the identity captured here, checked again at
    /// the moment of writing, and one delivery at a time per pane.
    private func configureAttachments(on pane: TerminalPane, identity: TerminalIdentity, target: WorkTarget) {
        pane.view.attachments = attachments
        pane.view.onAttachmentFailure = { [weak self] problem in
            guard let self else { return }
            if let path = problem.recoveredPath {
                // The file exists and is worth keeping: the user can copy the
                // path even though it did not reach the prompt.
                self.recoveredAttachmentPath = path
            }
            self.model.banner = .failure("That attachment was not added", problem.reason)
        }
        // Weak, both ways: the pane owns the view, the view owns this closure.
        // The identity and target are values captured here and never looked up
        // again, so a late arrival goes where it was dropped or nowhere.
        pane.view.onInsertText = { [weak self, weak pane] insertion in
            guard let self else { return }
            guard let pane else {
                self.recordInsertFailure(
                    insertion, reason: "That terminal is no longer open, so nothing was typed.")
                return
            }
            Task {
                do {
                    try await self.insert(
                        insertion.text, into: identity, target: target, clientPID: pane.clientPID)
                } catch {
                    self.recordInsertFailure(insertion, reason: "\(error)")
                }
            }
        }
    }

    /// An insertion that never reached the prompt. The file itself is fine —
    /// only the typing failed — so the path is kept rather than lost with it.
    func recordInsertFailure(_ insertion: MarmyTerminalView.Insertion, reason: String) {
        if let path = insertion.recoveredPath {
            recoveredAttachmentPath = path
        }
        model.banner = .failure("That attachment was not added", reason)
    }

    // MARK: - What an agent has been told

    /// Loads this agent's message history from the journal.
    ///
    /// Everything here is something Marmy handed over, exactly as it handed it
    /// over — never a re-render, and never a preview of what a future launch
    /// would say.
    public func loadMessages(for nodeID: UUID) async {
        do {
            messages[nodeID] = try await model.runtime.journal.entries(forNode: nodeID)
        } catch {
            model.banner = .failure("Could not read the message history", "\(error)")
        }
    }

    /// Whether this agent was attached rather than started by Marmy.
    public func isAdopted(_ nodeID: UUID) -> Bool {
        model.binding(for: nodeID)?.ownership == .adopted
    }

    /// Whether there is anything this agent may have been told that Marmy
    /// cannot account for.
    ///
    /// An adopted session was running before Marmy saw it. A session Marmy did
    /// start, but with no starting prompt on record, was started before Marmy
    /// kept one. Either way "nothing was sent" would be a guess, and the
    /// difference between the two is worth saying out loud.
    public func priorHistoryIsUnknown(_ nodeID: UUID) -> Bool {
        guard case .running = model.state(of: nodeID) else { return false }
        if isAdopted(nodeID) { return true }
        guard let entries = messages[nodeID] else { return false }
        return !entries.contains { $0.kind == .launchPrompt }
    }

    /// How many messages to this agent are waiting or unaccounted for.
    public func unsettledMessageCount(_ nodeID: UUID) -> Int {
        roster.pendingItems(forNode: nodeID).count
    }

    /// Copies a message so it can be pasted by hand.
    public func copy(_ text: String) {
        attachmentPasteboard.clearContents()
        attachmentPasteboard.setString(text, forType: .string)
    }

    /// Puts the kept file's path on the clipboard, for a prompt that never got it.
    public func copyRecoveredAttachmentPath() {
        guard let path = recoveredAttachmentPath else { return }
        attachmentPasteboard.clearContents()
        attachmentPasteboard.setString(path, forType: .string)
    }

    /// Shows the kept file in the Finder.
    public func revealRecoveredAttachment() {
        guard let path = recoveredAttachmentPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    public func dismissRecoveredAttachment() {
        recoveredAttachmentPath = nil
    }

    public func reconnectTerminal() {
        guard let target = model.selectedTarget,
              let identity = terminalIdentity(for: target),
              let session = model.attachedSession(for: target)
        else { return }
        retireScrollDrain()
        let pane = terminals.reconnect(
            identity,
            sessionName: session.name,
            attachment: model.runtime.tmux.attachment(sessionID: identity.sessionID))
        configureAttachments(on: pane, identity: identity, target: target)
        currentPane = pane
    }

    /// Puts the keyboard into the selected terminal, once it is on screen and as
    /// long as they are not part-way through typing in a field.
    public func focusTerminal(attemptsLeft: Int = 3) {
        guard let view = currentPane?.view else { return }
        guard let window = view.window else {
            guard attemptsLeft > 0 else { return }
            DispatchQueue.main.async { [weak self] in
                self?.focusTerminal(attemptsLeft: attemptsLeft - 1)
            }
            return
        }
        if let responder = window.firstResponder as? NSTextView, responder.isEditable { return }
        window.makeFirstResponder(view)
    }

    // MARK: - Sending

    /// The microphone button: press and hold.
    public func micPressed() {
        beginDictation()
    }

    public func micReleased() {
        voice.endHold()
    }

    /// Starts dictating to the agent on screen, remembering exactly which
    /// terminal that is. Everything spoken belongs to that one.
    private func beginDictation() {
        guard let target = model.selectedTarget else { return }
        guard !voice.isCapturing, voice.status != .finishing else { return }
        // Words already spoken and not yet dealt with must not be pushed aside
        // by new ones.
        guard !dictation.hasUnresolved(for: target) else {
            model.banner = Banner(
                kind: .warning,
                title: "There is dictation waiting for this agent",
                detail: "Put it in the prompt, copy it, or discard it first — then hold Space again.")
            return
        }
        guard let identity = terminalIdentity(for: target), let pane = currentPane,
              pane.identity == identity, pane.connection == .attached
        else {
            model.banner = .failure(
                "Nothing to dictate to",
                "This agent's terminal is not connected, so there is nowhere to put what you say. "
                    + "Start or reconnect it first.")
            return
        }

        voice.beginHold(on: target)
        guard let captureID = voice.captureID else { return }
        dictationOrigins[captureID] = DictationOrigin(
            target: target, identity: identity, clientPID: pane.clientPID == 0 ? nil : pane.clientPID)
    }

    /// Puts a finished dictation into the prompt it was spoken for.
    ///
    /// Nothing is submitted: the words land where the user can read them, change
    /// them, and press Enter themselves. If the terminal is not the one they
    /// were spoken to any more, the text stays here rather than being typed into
    /// something else.
    public func deliverDictation(_ captureID: UUID) async {
        guard let item = dictation.item(id: captureID) else { return }
        guard !inFlightPastes.contains(captureID) else { return }
        inFlightPastes.insert(captureID)
        defer { inFlightPastes.remove(captureID) }

        dictation.markPasting(captureID)

        // The terminal must still be the one the words were spoken to, and the
        // user must still be looking at it.
        guard model.selectedTarget == item.target,
              terminalIdentity(for: item.target) == item.identity,
              let pane = currentPane, pane.identity == item.identity
        else {
            dictation.markFailed(
                captureID,
                reason: "This agent's terminal changed while you were speaking, so nothing was pasted.")
            return
        }

        do {
            try await insert(item.text, into: item.identity, target: item.target, clientPID: pane.clientPID)
            dictation.discard(captureID)
            focusTerminal()
        } catch let error as RuntimeError {
            switch error {
            case .deliveryUncertain:
                // It may already be in the prompt. Nobody should repeat a long
                // dictation on a guess.
                dictation.markUncertain(captureID, reason: "\(error)")
            default:
                dictation.markFailed(captureID, reason: "\(error)")
            }
        } catch {
            dictation.markFailed(captureID, reason: "\(error)")
        }
    }

    /// Puts text into one exact pane, through the runtime's checks and its
    /// per-pane queue, so nothing else can land in the middle of it.
    func insert(
        _ text: String,
        into identity: TerminalIdentity,
        target: WorkTarget,
        clientPID: Int32
    ) async throws {
        // Nothing this drain has queued may arrive after what is about to be
        // typed. Leaving the scrollback happens inside the paste itself, while
        // the pane is held, so a wheel gesture cannot scroll it away in between.
        retireScrollDrain()

        let expected = AgentRuntime.DeliveryTarget(
            sessionID: identity.sessionID,
            paneID: identity.paneID,
            server: identity.server,
            generation: UUID(uuidString: identity.generation))
        switch target {
        case .node(let nodeID):
            try await model.runtime.paste(
                text, toNode: nodeID, expecting: expected,
                fromClient: clientPID == 0 ? nil : clientPID)
        case .localSession:
            try await model.runtime.paste(
                text, toSessionID: identity.sessionID, expecting: expected,
                fromClient: clientPID == 0 ? nil : clientPID)
        }
    }

    /// Tries a held dictation again, at the user's word.
    public func retryDictation(_ captureID: UUID) async {
        guard var item = dictation.item(id: captureID) else { return }
        guard !inFlightPastes.contains(captureID) else { return }
        // The terminal may be a different one now; the words still belong to
        // this agent, so retry against where it is today.
        if let identity = terminalIdentity(for: item.target) {
            item.identity = identity
            item.clientPID = currentPane?.clientPID
            dictation.hold(item)
        }
        await deliverDictation(captureID)
    }

    public func discardDictation(_ captureID: UUID) {
        dictation.discard(captureID)
    }

    /// Used when there is no terminal to name — the words are still kept.
    private func unknownIdentity(for target: WorkTarget) -> TerminalIdentity {
        TerminalIdentity(
            target: target,
            server: model.readout.server ?? TmuxServerIdentity(pid: 0, socketPath: "", startTime: 0),
            sessionID: "", paneID: "")
    }
}
