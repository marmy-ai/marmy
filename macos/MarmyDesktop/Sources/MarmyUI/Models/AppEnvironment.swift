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
    /// Targets with a delivery in flight, so a button, a shortcut, and a menu
    /// item cannot all send the same draft at once.
    public private(set) var inFlightSends: Set<WorkTarget> = []

    @ObservationIgnored private var hintTask: Task<Void, Never>?
    @ObservationIgnored private var focusObservers: [Any] = []

    public init(model: AppModel, speechEngine: any SpeechEngine) {
        self.model = model
        self.voice = VoiceController(engine: speechEngine, drafts: model.drafts)
        configureKeyboard()
        // Every route into a different agent ends up here: clicks, keyboard,
        // menus, and a session vanishing during a refresh.
        model.onSelectionChanged = { [weak self] in
            self?.selectionChanged()
        }
    }

    public convenience init(model: AppModel) {
        self.init(model: model, speechEngine: AppleSpeechEngine())
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
            guard let self, let target = self.model.selectedTarget else { return }
            self.voice.beginHold(on: target)
        }
        keyboard.onHoldEnded = { [weak self] in
            self?.voice.endHold()
        }
        keyboard.onSpaceTap = { [weak self] in
            // A tap is an ordinary space and belongs to the terminal.
            guard let view = self?.currentPane?.view else { return }
            view.send(source: view, data: ArraySlice([UInt8(ascii: " ")]))
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
        keyboard.install()
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
        model.stopRefreshing()
        // Ends our tmux clients only. Every agent keeps running.
        terminals.releaseAll()
        for observer in focusObservers { NotificationCenter.default.removeObserver(observer) }
        focusObservers.removeAll()
    }

    public func stopCapture(reason: String?) {
        keyboard.cancelHold()
        voice.cancel(reason: reason)
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
        currentPane = terminals.pane(
            for: identity,
            sessionName: session.name,
            attachment: model.runtime.tmux.attachment(sessionID: identity.sessionID))
    }

    public func reconnectTerminal() {
        guard let target = model.selectedTarget,
              let identity = terminalIdentity(for: target),
              let session = model.attachedSession(for: target)
        else { return }
        currentPane = terminals.reconnect(
            identity,
            sessionName: session.name,
            attachment: model.runtime.tmux.attachment(sessionID: identity.sessionID))
    }

    /// Puts the keyboard into the selected terminal, once it is on screen and as
    /// long as the user is not mid-sentence in the composer.
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

    /// Sends the draft that belongs to `origin`.
    ///
    /// The origin is passed in by whoever asked — a button, a shortcut, a menu —
    /// so a selection change between the click and the delivery cannot send one
    /// agent's words to another. The message is only ever handed to the terminal
    /// client that is actually attached to that agent.
    public func sendDraft(from origin: WorkTarget) async {
        guard !inFlightSends.contains(origin) else { return }
        // A transcript may still be replacing this text; sending now would send
        // half a sentence.
        guard !model.drafts.isDictating(origin) else { return }
        guard let identity = terminalIdentity(for: origin),
              let pane = terminals.existingPane(for: identity),
              pane.connection == .attached,
              pane.clientPID != 0
        else {
            model.banner = .failure(
                "Message not sent",
                "This agent's terminal is not connected, so Marmy cannot confirm where the message "
                    + "would land. Reconnect it and try again — your draft is kept.")
            return
        }

        inFlightSends.insert(origin)
        defer { inFlightSends.remove(origin) }

        let delivered = await model.sendDraft(from: origin, clientPID: pane.clientPID)
        // Focus goes back to the terminal only if the user is still there and the
        // draft really went; otherwise leave them where they are.
        if delivered, model.selectedTarget == origin, model.drafts.isEmpty(origin) {
            focusTerminal()
        }
    }

    public func isSending(_ target: WorkTarget) -> Bool {
        inFlightSends.contains(target)
    }

    /// The microphone button: press and hold.
    public func micPressed() {
        guard let target = model.selectedTarget else { return }
        voice.beginHold(on: target)
    }

    public func micReleased() {
        voice.endHold()
    }
}
