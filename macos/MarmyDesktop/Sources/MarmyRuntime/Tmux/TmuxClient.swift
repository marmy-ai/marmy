import Foundation

/// A thin, typed wrapper over the tmux CLI.
///
/// Every call is a short-lived process run through an injectable
/// `CommandRunning`, so nothing here blocks the UI and every behavior is
/// testable without a live server. No call ever changes global tmux options or
/// touches sessions Marmy was not asked about.
public struct TmuxClient: Sendable {
    public let executablePath: String
    public let server: TmuxServerAddress
    private let runner: any CommandRunning

    public init(executablePath: String, server: TmuxServerAddress = .userDefault, runner: any CommandRunning) {
        self.executablePath = executablePath
        self.server = server
        self.runner = runner
    }

    /// Builds a client, failing with a clear message when tmux is not installed.
    public static func locate(
        server: TmuxServerAddress = .userDefault,
        locator: ExecutableLocator = ExecutableLocator(),
        runner: any CommandRunning = SystemCommandRunner()
    ) throws -> TmuxClient {
        do {
            return TmuxClient(executablePath: try locator.locateOrThrow("tmux"), server: server, runner: runner)
        } catch {
            throw TmuxError.tmuxNotInstalled(detail: "\(error)")
        }
    }

    // MARK: - Reading

    /// `nil` when no server is running on this socket, which is a normal state
    /// and not an error.
    public func serverIdentity() async throws -> TmuxServerIdentity? {
        let command = "display-message"
        let result = try await run([
            command, "-p", TmuxFormat.lengthPrefixed(["pid", "socket_path", "start_time"]),
        ])
        if Self.isNoServer(result) { return nil }
        try Self.requireSuccess(result, command: command)

        let fields = try TmuxFormat.parseRecord(result.standardOutputData, fieldCount: 3, command: command)
        return TmuxServerIdentity(
            pid: Int32(try TmuxFormat.integer(fields[0], command: command)),
            socketPath: fields[1],
            startTime: try TmuxFormat.integer(fields[2], command: command))
    }

    public func listSessions() async throws -> [TmuxSession] {
        let command = "list-sessions"
        let fields = ["session_id", "session_name", "session_created", "session_attached", "session_windows"]
        let result = try await run([command, "-F", TmuxFormat.lengthPrefixed(fields)])
        if Self.isNoServer(result) { return [] }
        try Self.requireSuccess(result, command: command)

        return try TmuxFormat.parseRecords(
            result.standardOutputData, fieldCount: fields.count, command: command
        ).map { record in
            TmuxSession(
                id: record[0],
                name: record[1],
                created: try TmuxFormat.integer(record[2], command: command),
                isAttached: try TmuxFormat.integer(record[3], command: command) > 0,
                windowCount: try TmuxFormat.integer(record[4], command: command))
        }
    }

    public func listPanes() async throws -> [TmuxPane] {
        let command = "list-panes"
        let fields = [
            "pane_id", "session_id", "session_name", "window_id",
            "pane_pid", "pane_current_command", "pane_current_path",
            "pane_active", "window_active", "pane_dead",
        ]
        let result = try await run([command, "-a", "-F", TmuxFormat.lengthPrefixed(fields)])
        if Self.isNoServer(result) { return [] }
        try Self.requireSuccess(result, command: command)

        return try TmuxFormat.parseRecords(
            result.standardOutputData, fieldCount: fields.count, command: command
        ).map { record in
            TmuxPane(
                id: record[0],
                sessionID: record[1],
                sessionName: record[2],
                windowID: record[3],
                pid: Int32(try TmuxFormat.integer(record[4], command: command)),
                currentCommand: record[5],
                currentPath: record[6],
                isActive: try TmuxFormat.integer(record[7], command: command) == 1,
                isWindowActive: try TmuxFormat.integer(record[8], command: command) == 1,
                isDead: try TmuxFormat.integer(record[9], command: command) == 1)
        }
    }

    /// Pane contents. `lines` reaches back into scrollback; `joinWrapped` puts a
    /// line the terminal wrapped back together, so text can be searched as it
    /// was written rather than as it was displayed.
    /// Terminals attached to this server. A client's session and pane change when
    /// the user switches inside tmux, which is how Marmy knows the embedded
    /// terminal is still looking at the agent it says it is.
    public func listClients() async throws -> [TmuxClientInfo] {
        let command = "list-clients"
        let fields = ["client_pid", "client_name", "session_id", "session_name", "pane_id"]
        let result = try await run([command, "-F", TmuxFormat.lengthPrefixed(fields)])
        if Self.isNoServer(result) { return [] }
        try Self.requireSuccess(result, command: command)

        return try TmuxFormat.parseRecords(
            result.standardOutputData, fieldCount: fields.count, command: command
        ).map { record in
            TmuxClientInfo(
                pid: Int32(try TmuxFormat.integer(record[0], command: command)),
                name: record[1],
                sessionID: record[2],
                sessionName: record[3],
                paneID: record[4])
        }
    }

    public func capturePane(
        _ paneID: String,
        lines: Int? = nil,
        joinWrapped: Bool = false
    ) async throws -> String {
        var arguments = ["capture-pane", "-p", "-t", paneID]
        if joinWrapped { arguments.append("-J") }
        if let lines { arguments += ["-S", "-\(lines)"] }
        let result = try await run(arguments)
        try Self.requireSuccess(result, command: "capture-pane")
        return result.standardOutput
    }

    // MARK: - Starting

    /// Starts a detached session running `executable` directly — tmux execs the
    /// argument vector itself, so nothing is passed through a shell.
    public func newSession(
        name: String,
        directory: String,
        executable: String,
        arguments: [String]
    ) async throws -> TmuxStartedSession {
        let command = "new-session"
        let format = TmuxFormat.lengthPrefixed(["session_id", "session_name", "pane_id"])
        let result = try await run(
            [command, "-d", "-s", name, "-c", directory, "-P", "-F", format, executable] + arguments,
            timeout: 20)
        try Self.requireSuccess(result, command: command)

        let fields = try TmuxFormat.parseRecord(result.standardOutputData, fieldCount: 3, command: command)
        return TmuxStartedSession(sessionID: fields[0], sessionName: fields[1], paneID: fields[2])
    }

    /// Sets a `@marmy_*` user option on one session Marmy started. Session
    /// scoped: no global option is ever touched.
    ///
    /// `target` must be a stable id (`$3`) or the `=name:` pane-target form;
    /// set-option resolves `-t` as a pane target, so a bare `=name` is rejected.
    public func setSessionOption(_ name: String, value: String, target: String) async throws {
        let result = try await run(["set-option", "-t", target, name, value])
        try Self.requireSuccess(result, command: "set-option")
    }

    /// The value of a session user option, or `nil` when it is not set.
    public func sessionOption(_ name: String, target: String) async throws -> String? {
        let result = try await run(["show-options", "-v", "-t", target, name])
        if !result.isSuccess { return nil }
        let value = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Only ever called for a session the user explicitly asked to stop, and by
    /// tests cleaning up their own private server.
    public func killSession(target: String) async throws {
        let result = try await run(["kill-session", "-t", target])
        try Self.requireSuccess(result, command: "kill-session")
    }

    // MARK: - Sending text

    /// Loads text into a named buffer through stdin, so the text itself never
    /// passes through tmux's command parser or any shell.
    public func loadBuffer(name: String, text: String) async throws {
        let result = try await run(["load-buffer", "-b", name, "-"], standardInput: Data(text.utf8))
        try Self.requireSuccess(result, command: "load-buffer")
    }

    /// Pastes a buffer into one exact pane. `-d` deletes the buffer afterwards,
    /// `-p` brackets the paste, `-r` keeps newlines as they were written.
    public func pasteBuffer(name: String, target: String) async throws {
        let result = try await run(["paste-buffer", "-d", "-p", "-r", "-t", target, "-b", name])
        try Self.requireSuccess(result, command: "paste-buffer")
    }

    public func deleteBuffer(name: String) async throws {
        let result = try await run(["delete-buffer", "-b", name])
        try Self.requireSuccess(result, command: "delete-buffer")
    }

    /// Sends Enter on its own, after the pasted text has landed.
    public func sendEnter(target: String) async throws {
        let result = try await run(["send-keys", "-t", target, "Enter"])
        try Self.requireSuccess(result, command: "send-keys")
    }

    // MARK: - Plumbing

    @discardableResult
    func run(_ arguments: [String], standardInput: Data? = nil, timeout: TimeInterval = 10) async throws -> CommandResult {
        try await runner.run(CommandInvocation(
            executable: executablePath,
            arguments: server.arguments + arguments,
            environment: environmentForTmuxCommands(),
            standardInput: standardInput,
            timeout: timeout))
    }

    /// The controller must not inherit a stale `TMUX` from whatever pane the app
    /// was launched from, or tmux would refuse commands or address the wrong
    /// server instead of the socket Marmy is configured for.
    private func environmentForTmuxCommands() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "TMUX")
        environment.removeValue(forKey: "TMUX_PANE")
        return environment
    }

    /// True only for "there is no server on this socket", which is a normal
    /// state. A socket that exists but cannot be opened — permission denied,
    /// sandbox refusal — is a real error and must not read as "no sessions".
    static func isNoServer(_ result: CommandResult) -> Bool {
        guard !result.isSuccess else { return false }
        let text = result.standardError.lowercased()
        if text.contains("no server running") { return true }
        guard text.contains("error connecting to") else { return false }
        // tmux appends the strerror reason in parentheses.
        return text.contains("no such file or directory") || text.contains("connection refused")
    }

    static func requireSuccess(_ result: CommandResult, command: String) throws {
        guard !result.isSuccess else { return }
        throw TmuxError.commandFailed(command: command, detail: result.failureText)
    }

}
