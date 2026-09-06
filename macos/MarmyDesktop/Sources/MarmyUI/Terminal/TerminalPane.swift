import AppKit
import Foundation
import MarmyRuntime
import Observation
import SwiftTerm

/// How the embedded terminal for one target is doing.
public enum TerminalConnection: Equatable, Sendable {
    case attaching
    case attached
    /// The tmux client exited. The agent's session is untouched — only this
    /// window's view of it went away.
    case detached(reason: String)
}

/// Everything that has to match for a cached terminal to still be the right one.
///
/// A relaunched agent, a restarted tmux, or a different pane all mean the old
/// client is looking at something else — or at nothing — so the cache is keyed
/// by the whole live identity, not just the session id.
public struct TerminalIdentity: Hashable, Sendable {
    public var target: WorkTarget
    public var server: TmuxServerIdentity
    public var sessionID: String
    public var paneID: String
    /// The launch generation for a team member; empty for a local session.
    public var generation: String

    public init(
        target: WorkTarget,
        server: TmuxServerIdentity,
        sessionID: String,
        paneID: String,
        generation: String = ""
    ) {
        self.target = target
        self.server = server
        self.sessionID = sessionID
        self.paneID = paneID
        self.generation = generation
    }

    public var key: String {
        "\(target.id)#\(server.socketPath):\(server.pid):\(server.startTime)#\(sessionID)#\(paneID)#\(generation)"
    }
}

/// One embedded terminal: a real tmux client attached to one exact session.
///
/// The client is shared (`attach-session` with no `-d`), so any terminal the
/// user already had attached keeps working, and ending this client never ends
/// the agent.
@MainActor
@Observable
public final class TerminalPane {
    public let identity: TerminalIdentity
    public var key: String { identity.key }
    public let sessionID: String
    public private(set) var sessionName: String
    public private(set) var connection: TerminalConnection = .attaching
    /// PID of the tmux client process, which is what `list-clients` reports.
    public private(set) var clientPID: pid_t = 0

    @ObservationIgnored public let view: LocalProcessTerminalView
    @ObservationIgnored private let attachment: TmuxAttachment
    @ObservationIgnored private var delegateBox: ProcessDelegate?

    init(identity: TerminalIdentity, sessionName: String, attachment: TmuxAttachment) {
        self.identity = identity
        self.sessionID = identity.sessionID
        self.sessionName = sessionName
        self.attachment = attachment
        self.view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 520))
        // The view is its own terminalDelegate; only processDelegate is ours.
        let box = ProcessDelegate(owner: self)
        self.delegateBox = box
        view.processDelegate = box
    }

    func start() {
        connection = .attaching
        view.startProcess(
            executable: attachment.executablePath,
            args: attachment.arguments,
            environment: attachment.environmentStrings,
            execName: nil,
            currentDirectory: nil)
        // A failed fork returns quietly, leaving the process not running. Saying
        // "attached" then would be a lie the user could not act on.
        guard view.process.running, view.process.shellPid != 0 else {
            connection = .detached(reason:
                "Could not start a tmux client for \(sessionName). Check that tmux is installed and try again.")
            return
        }
        clientPID = view.process.shellPid
        connection = .attached
    }

    /// Ends this client only.
    ///
    /// SwiftTerm keeps `shellPid` after the process exits and its `terminate()`
    /// signals whatever PID it holds, so an already-exited client must never be
    /// terminated again — that PID may belong to something else by now.
    func stop() {
        guard view.process.running else { return }
        view.terminate()
    }

    func rename(to name: String) {
        sessionName = name
    }

    fileprivate func processEnded(exitCode: Int32?) {
        let reason: String
        if let exitCode, exitCode != 0 {
            reason = "The terminal connection closed (exit \(exitCode)). The agent's session is unaffected."
        } else {
            reason = "The terminal connection closed. The agent's session is unaffected."
        }
        connection = .detached(reason: reason)
    }

    /// Kept separate so the terminal view's own delegate is never replaced.
    private final class ProcessDelegate: NSObject, LocalProcessTerminalViewDelegate {
        weak var owner: TerminalPane?

        init(owner: TerminalPane) {
            self.owner = owner
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            MainActor.assumeIsolated {
                owner?.processEnded(exitCode: exitCode)
            }
        }
    }
}

/// Keeps one live terminal per live identity and cleans up the rest.
@MainActor
@Observable
public final class TerminalController {
    /// How many attached clients to keep while switching agents. Each is a real
    /// tmux client process, so the cache is deliberately small.
    public static let cacheLimit = 6

    private var panes: [String: TerminalPane] = [:]
    private var order: [String] = []

    public init() {}

    public var activePaneCount: Int { panes.count }

    /// The terminal for one live identity, attaching a client the first time.
    ///
    /// A target whose identity changed — relaunched agent, restarted tmux,
    /// different pane — gets a new client, and its stale one is released.
    @discardableResult
    public func pane(
        for identity: TerminalIdentity,
        sessionName: String,
        attachment: TmuxAttachment
    ) -> TerminalPane {
        if let existing = panes[identity.key] {
            existing.rename(to: sessionName)
            touch(identity.key)
            return existing
        }
        releasePanes(for: identity.target)

        let pane = TerminalPane(identity: identity, sessionName: sessionName, attachment: attachment)
        panes[identity.key] = pane
        touch(identity.key)
        pane.start()
        evictIfNeeded()
        return pane
    }

    public func existingPane(for identity: TerminalIdentity) -> TerminalPane? {
        panes[identity.key]
    }

    /// Replaces a terminal with a fresh client.
    ///
    /// The old view is thrown away rather than restarted: SwiftTerm's process
    /// refuses to start again while it still believes it is running, so a
    /// reconnect that reused it would quietly do nothing.
    @discardableResult
    public func reconnect(
        _ identity: TerminalIdentity,
        sessionName: String,
        attachment: TmuxAttachment
    ) -> TerminalPane {
        if let existing = panes.removeValue(forKey: identity.key) {
            existing.stop()
            order.removeAll { $0 == identity.key }
        }
        return pane(for: identity, sessionName: sessionName, attachment: attachment)
    }

    public func release(_ pane: TerminalPane) {
        pane.stop()
        panes.removeValue(forKey: pane.key)
        order.removeAll { $0 == pane.key }
    }

    /// Ends every client. Called when the app quits: the agents keep running.
    public func releaseAll() {
        for pane in panes.values { pane.stop() }
        panes.removeAll()
        order.removeAll()
    }

    private func releasePanes(for target: WorkTarget) {
        let prefix = "\(target.id)#"
        for (key, pane) in panes where key.hasPrefix(prefix) {
            pane.stop()
            panes.removeValue(forKey: key)
            order.removeAll { $0 == key }
        }
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func evictIfNeeded() {
        while order.count > Self.cacheLimit, let oldest = order.first {
            order.removeFirst()
            panes.removeValue(forKey: oldest)?.stop()
        }
    }
}
