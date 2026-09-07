import Foundation
import MarmyCore
import MarmyRuntime
import Observation

/// Exactly which live thing a history read is for.
///
/// A `WorkTarget` is not enough: the same agent can be relaunched, tmux can be
/// restarted, and the embedded terminal can be reconnected — all without the
/// target's id changing. History is read against the identity that was on screen
/// when the gesture happened, and a read that no longer matches is thrown away.
public struct HistoryRequest: Hashable, Sendable {
    public var target: WorkTarget
    public var identity: TerminalIdentity
    /// The embedded tmux client showing this pane, when there is one.
    public var clientPID: Int32?
    public var maxLines: Int

    public init(target: WorkTarget, identity: TerminalIdentity, clientPID: Int32?, maxLines: Int) {
        self.target = target
        self.identity = identity
        self.clientPID = clientPID
        self.maxLines = max(0, maxLines)
    }
}

/// Where scrollback comes from. The app talks to tmux through this; tests hand
/// it a fixture instead.
@MainActor
public protocol PaneHistorySource: AnyObject {
    func history(for request: HistoryRequest) async throws -> PaneHistory
}

/// Marmy's own view of a pane's scrollback.
///
/// The terminal itself cannot scroll: a tmux client draws on the alternate
/// screen, which has no scrollback of its own, and the transcript lives in
/// tmux's pane history. Scrolling up therefore reads that history with
/// `capture-pane` and shows it here — read-only, in the app, with nothing sent
/// to the agent and no tmux mode entered, so other clients attached to the same
/// session see nothing change.
///
/// The snapshot is deliberately frozen while you read it. New output keeps
/// arriving in the live terminal underneath; the header says so, and one click
/// takes you back.
@MainActor
@Observable
public final class TerminalHistoryController {
    public enum Mode: Equatable {
        case live
        case history
    }

    public private(set) var mode: Mode = .live
    public private(set) var snapshot: PaneHistory?
    /// What the snapshot is of, so a selection change, a relaunch, or a
    /// reconnect closes it.
    public private(set) var request: HistoryRequest?

    public var target: WorkTarget? { request?.target }
    public private(set) var isLoading = false
    public private(set) var failure: String?
    /// How far up the wheel had moved when history opened, so the view can start
    /// where the eye already was rather than snapping to the very bottom.
    public private(set) var initialLinesFromBottom = 0

    /// How much scrollback to read. tmux keeps 2000 lines per pane by default.
    public var maxLines = 5000

    @ObservationIgnored private weak var source: (any PaneHistorySource)?
    @ObservationIgnored private var loadToken = 0

    public init(source: (any PaneHistorySource)? = nil) {
        self.source = source
    }

    public func attach(source: any PaneHistorySource) {
        self.source = source
    }

    public var isShowingHistory: Bool { mode == .history }

    /// A wheel gesture over the terminal. Positive is upward.
    public func scrolled(lines: Int, on target: WorkTarget, identity: TerminalIdentity, clientPID: Int32?) async {
        guard mode == .live, lines > 0 else { return }
        await openHistory(
            HistoryRequest(target: target, identity: identity, clientPID: clientPID, maxLines: maxLines),
            linesFromBottom: lines)
    }

    /// Opens the history view for one live identity, or reports why it could not.
    public func openHistory(_ request: HistoryRequest, linesFromBottom: Int = 0) async {
        guard let source else { return }
        loadToken += 1
        let token = loadToken
        isLoading = true
        failure = nil
        self.request = request
        // Shown immediately so the gesture feels answered, even on a slow read.
        mode = .history
        initialLinesFromBottom = max(0, linesFromBottom)

        do {
            let history = try await source.history(for: request)
            // A reconnect or a selection change while the read was in flight
            // retires it: this snapshot is of something nobody is looking at.
            guard token == loadToken, self.request == request else { return }
            snapshot = history
            isLoading = false
        } catch {
            guard token == loadToken, self.request == request else { return }
            isLoading = false
            failure = "\(error)"
            snapshot = nil
        }
    }

    /// Reads the pane again, keeping the history view open.
    public func refresh() async {
        guard mode == .history, let request else { return }
        await openHistory(request, linesFromBottom: initialLinesFromBottom)
    }

    /// Back to the live terminal.
    public func returnToLive() {
        loadToken += 1
        mode = .live
        snapshot = nil
        request = nil
        failure = nil
        isLoading = false
        initialLinesFromBottom = 0
    }

    /// Called when the selection moves: history belongs to one agent.
    public func selectionChanged(to newTarget: WorkTarget?) {
        guard mode == .history else { return }
        if newTarget != request?.target { returnToLive() }
    }

    /// Called when the terminal underneath changes — a relaunch, a reconnect, a
    /// restarted tmux — even though the agent is the same one.
    public func identityChanged(to identity: TerminalIdentity?) {
        guard mode == .history, let request else { return }
        if identity != request.identity { returnToLive() }
    }
}
