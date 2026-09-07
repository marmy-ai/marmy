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
    /// Marmy's own scrollback view, because a tmux client cannot scroll.
    public let history = TerminalHistoryController()
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
    /// Briefly shown after keyboard navigation, then fades.
    public private(set) var locationHintToken = 0

    @ObservationIgnored private var hintTask: Task<Void, Never>?
    /// Where each capture was spoken, by capture id. A new hold never disturbs
    /// an older capture's origin.
    @ObservationIgnored private var dictationOrigins: [UUID: DictationOrigin] = [:]
    @ObservationIgnored private var inFlightPastes: Set<UUID> = []

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
        history.attach(source: self)
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
        keyboard.onEscape = { [weak self] in
            guard let self, self.history.isShowingHistory else { return false }
            self.history.returnToLive()
            self.focusTerminal()
            return true
        }
        keyboard.onSpaceTap = { [weak self] in
            // A tap is an ordinary space and belongs to the terminal.
            guard let view = self?.currentPane?.view else { return }
            view.send(source: view, data: ArraySlice([UInt8(ascii: " ")]))
        }
    }

    /// The wheel over the terminal opens Marmy's history instead of being
    /// forwarded, which is what used to type arrow keys into the agent.
    private func configureScrolling() {
        scrollMonitor.terminalView = { [weak self] in self?.currentPane?.view }
        // The event is always taken from the terminal; this only decides whether
        // it also moves the history view.
        scrollMonitor.shouldReportScroll = { [weak self] in
            guard let self else { return false }
            return self.history.mode == .live && !self.isModalPresented && self.teamPendingDeletion == nil
        }
        scrollMonitor.onScrollLines = { [weak self] lines in
            guard let self,
                  let target = self.model.selectedTarget,
                  let identity = self.terminalIdentity(for: target),
                  let pane = self.currentPane,
                  pane.identity == identity
            else { return }
            let clientPID = pane.clientPID == 0 ? nil : pane.clientPID
            Task {
                await self.history.scrolled(
                    lines: lines, on: target, identity: identity, clientPID: clientPID)
            }
        }
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
        history.returnToLive()
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
        // History belongs to one agent; looking at someone else closes it.
        history.selectionChanged(to: model.selectedTarget)
        currentPane = nil
    }

    /// Asks for confirmation before removing a team.
    ///
    /// Recording stops as the question goes up: the agent being dictated to may
    /// be one of the ones about to disappear, and a confirmation is a modal
    /// moment either way.
    public func requestDeletion(of topology: Topology) {
        stopCapture(reason: nil)
        teamPendingDeletion = topology
    }

    /// Removes the team the user confirmed.
    ///
    /// The id comes from the button that was pressed, not from
    /// `teamPendingDeletion`: SwiftUI clears the presentation binding before the
    /// action's task runs, and reading it here would delete nothing.
    public func confirmDeletion(of topologyID: UUID) async {
        teamPendingDeletion = nil
        stopCapture(reason: nil)
        await model.deleteTopology(topologyID)
    }

    /// Cancelling changes nothing at all.
    public func cancelDeletion() {
        teamPendingDeletion = nil
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
        // The terminal underneath is changing, so any history of the old one is
        // no longer what the user is looking at.
        history.identityChanged(to: identity)
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
        history.returnToLive()
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

/// Scrollback comes from the same runtime that owns the bindings, so history is
/// read from the pane this agent is actually attached to and nothing else.
extension AppEnvironment: PaneHistorySource {
    public func history(for request: HistoryRequest) async throws -> PaneHistory {
        let identity = request.identity
        switch request.target {
        case .node(let nodeID):
            return try await model.runtime.history(
                paneID: identity.paneID,
                sessionID: identity.sessionID,
                onServer: identity.server,
                nodeID: nodeID,
                generation: UUID(uuidString: identity.generation),
                clientPID: request.clientPID,
                maxLines: request.maxLines)
        case .localSession(let key):
            return try await model.runtime.history(
                paneID: identity.paneID,
                sessionID: key.sessionID,
                onServer: key.server,
                clientPID: request.clientPID,
                maxLines: request.maxLines)
        }
    }
}
