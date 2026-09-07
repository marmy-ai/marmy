import XCTest
import MarmyCore
@testable import MarmyRuntime

/// End-to-end tests against a real tmux server.
///
/// Opt in with `MARMY_RUN_TMUX_TESTS=1`. Every run creates its own private
/// socket with `-f /dev/null`, so the user's own tmux server is never contacted,
/// listed, or changed. The only program these tests ever start is a fixture
/// script that echoes its arguments and then runs `cat` — no agent CLI is
/// launched and no model is ever called.
final class TmuxIntegrationTests: XCTestCase {

    private var environment: TestEnvironment!
    private var socketName: String!
    private var server: TmuxServerAddress!
    private var tmuxPath: String!
    private var tmux: TmuxClient!
    private let runner = SystemCommandRunner()

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MARMY_RUN_TMUX_TESTS"] == "1",
            "set MARMY_RUN_TMUX_TESTS=1 to run the tmux integration tests")
        guard let path = ExecutableLocator().locate("tmux") else {
            throw XCTSkip("tmux is not installed")
        }

        environment = try TestEnvironment()
        tmuxPath = path
        socketName = "marmy-test-\(UUID().uuidString.prefix(8).lowercased())"
        server = .named(socketName, configFile: "/dev/null")
        tmux = TmuxClient(executablePath: tmuxPath, server: server, runner: runner)

        // The fixture "CLI": prints its arguments, then becomes cat so the pane
        // stays alive and echoes anything typed into it. Absolute paths only —
        // a launched agent gets the locator's PATH, which here is just the
        // directory holding this fixture.
        try environment.writeExecutable(named: "claude", contents: """
        #!/bin/sh
        printf 'ARGS<%s>\\n' "$*"
        exec /bin/cat
        """)
    }

    override func tearDown() async throws {
        if let tmux {
            _ = try? await tmux.run(["kill-server"])
        }
        environment?.cleanUp()
    }

    // MARK: - Helpers

    /// The trampoline the app itself would use, resolved from the built products
    /// directory so these tests exercise the real helper and its real flags.
    private func realTrampoline() throws -> TrampolineCommand {
        let builtProducts = Bundle(for: TmuxIntegrationTests.self).bundleURL.deletingLastPathComponent()
        let command = TrampolineCommand.resolveDefault(
            executablePath: builtProducts.appendingPathComponent("MarmyDesktop").path)
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: command.executablePath),
            "the launch trampoline has not been built")
        return command
    }

    private func makeRuntime() throws -> AgentRuntime {
        try AgentRuntime(
            tmux: tmux,
            locator: environment.locator,
            store: environment.store,
            trampoline: try realTrampoline())
    }

    private var topology: Topology { Team.topology(workingDirectory: environment.workingDirectory.path) }
    private var workspace: Workspace { Team.workspace(workingDirectory: environment.workingDirectory.path) }

    private func startFixtureSession(named name: String) async throws -> TmuxStartedSession {
        try await tmux.newSession(
            name: name, directory: environment.workingDirectory.path,
            executable: "/bin/cat", arguments: [])
    }

    /// A bootstrap prompt is far longer than a 24-line pane, so assertions read
    /// the scrollback with wrapped lines rejoined.
    private func capture(_ paneID: String) async throws -> String {
        try await tmux.capturePane(paneID, lines: 2000, joinWrapped: true)
    }

    /// Waits for `predicate` to hold, polling the pane's contents.
    @discardableResult
    private func waitForPane(_ paneID: String, toContain text: String, timeout: TimeInterval = 5) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var contents = ""
        while Date() < deadline {
            contents = try await capture(paneID)
            if contents.contains(text) { return contents }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("pane \(paneID) never contained \u{22}\(text)\u{22}. Contents:\n\(contents)")
        return contents
    }

    // MARK: - Tests

    func testLaunchStartsLiveAgentsThroughTheRealTrampoline() async throws {
        let runtime = try makeRuntime()
        let outcome = await runtime.launch(topology: topology, workspace: workspace)

        XCTAssertTrue(outcome.isFullSuccess, "\(outcome.failures) \(outcome.preflight.errors.map(\.message))")
        XCTAssertEqual(outcome.started.count, 2)

        let sessions = try await tmux.listSessions()
        XCTAssertEqual(Set(sessions.map(\.name)), ["lead", "build"])

        // The rendered prompt arrived as one argument, after the end-of-options
        // marker, with its newlines intact.
        let binding = try XCTUnwrap(outcome.started[Team.workerID])
        let contents = try await waitForPane(binding.paneID, toContain: "ARGS<")
        XCTAssertTrue(contents.contains("You are Build"))
        XCTAssertTrue(contents.contains("--"))

        // Ownership is marked on the session Marmy created.
        let marker = try await tmux.sessionOption(
            AgentBinding.ownershipOptionName, target: binding.sessionID)
        XCTAssertEqual(marker, binding.ownershipMarker)

        // And the runtime reports it as running.
        let snapshot = try await runtime.snapshot(topology: topology)
        XCTAssertTrue(snapshot.state(of: Team.workerID).isRunning)
        XCTAssertTrue(snapshot.state(of: Team.managerID).isRunning)
    }

    func testMessagesArriveLiterallyAndLeaveNoBufferBehind() async throws {
        let runtime = try makeRuntime()
        let outcome = await runtime.launch(
            topology: topology, workspace: workspace, nodeIDs: [Team.workerID])
        let binding = try XCTUnwrap(outcome.started[Team.workerID])
        try await waitForPane(binding.paneID, toContain: "ARGS<")

        let marker = "MARKER-\(UUID().uuidString.prefix(6))"
        let message = """
        \(marker) first line; echo pwned
        second "quoted" `backtick` $HOME $(touch /tmp/marmy-should-not-exist)
        -leading dash
        ünicode ✅ done
        """
        try await runtime.send(message, toNode: Team.workerID)

        let contents = try await waitForPane(binding.paneID, toContain: "ünicode ✅ done")
        XCTAssertTrue(contents.contains("\(marker) first line; echo pwned"))
        XCTAssertTrue(contents.contains("second \u{22}quoted\u{22} `backtick` $HOME $(touch /tmp/marmy-should-not-exist)"))
        XCTAssertTrue(contents.contains("-leading dash"))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: "/tmp/marmy-should-not-exist"),
            "message text must never be evaluated by a shell")

        // paste-buffer -d removed the private buffer.
        let buffers = try await tmux.run(["list-buffers"])
        XCTAssertFalse(buffers.standardOutput.contains("marmy-"), buffers.standardOutput)
    }

    func testASessionNameCollisionIsRefusedAndTheExistingSessionIsUntouched() async throws {
        let existing = try await startFixtureSession(named: "build")
        let before = try await capture(existing.paneID)

        let runtime = try makeRuntime()
        let outcome = await runtime.launch(topology: topology, workspace: workspace)

        XCTAssertTrue(outcome.preflight.isBlocked)
        XCTAssertTrue(outcome.started.isEmpty, "a blocked preflight starts nothing, not even the other node")

        let sessions = try await tmux.listSessions()
        XCTAssertEqual(sessions.map(\.name), ["build"], "the manager was not started either")
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.id, existing.sessionID, "the existing session was never replaced")
        let afterCollision = try await capture(existing.paneID)
        XCTAssertEqual(afterCollision, before, "and nothing was typed into it")
    }

    func testPartialFailureKeepsWhatStartedAndRetryStartsOnlyTheRest() async throws {
        // The worker's name is taken by a session Marmy does not own. The
        // anchor keeps the server up when that blocker is killed.
        _ = try await startFixtureSession(named: "anchor")
        var team = topology
        team.nodes[1].sessionName = "build"
        let blocker = try await startFixtureSession(named: "build")

        let runtime = try makeRuntime()
        let blocked = await runtime.launch(topology: team, workspace: workspace)
        XCTAssertTrue(blocked.preflight.isBlocked)

        // Free the name and start only the manager, then retry the whole team.
        try await tmux.killSession(target: blocker.sessionID)
        let first = await runtime.launch(topology: team, workspace: workspace, nodeIDs: [Team.managerID])
        XCTAssertEqual(first.started.count, 1)
        let managerBinding = try XCTUnwrap(first.started[Team.managerID])

        let retry = await runtime.launch(topology: team, workspace: workspace)
        XCTAssertEqual(Array(retry.started.keys), [Team.workerID])
        XCTAssertEqual(retry.skipped[Team.managerID], "already running in lead")

        // The manager kept running through the retry: same session, same pane.
        let snapshot = try await runtime.snapshot(topology: team)
        XCTAssertEqual(
            snapshot.state(of: Team.managerID),
            .running(paneID: managerBinding.paneID, sessionName: "lead", adopted: false))
    }

    func testAdoptedSessionsReceiveNoBootstrapAtAll() async throws {
        // A plain shell-like session the user already had.
        let existing = try await startFixtureSession(named: "marmy_worker_opus")
        let before = try await capture(existing.paneID)

        let runtime = try makeRuntime()
        let binding = try await runtime.adopt(
            sessionName: "marmy_worker_opus", nodeID: Team.workerID, topology: topology, cli: .codex)

        XCTAssertEqual(binding.ownership, .adopted)
        try await Task.sleep(nanoseconds: 300_000_000)
        let afterAdoption = try await capture(existing.paneID)
        XCTAssertEqual(afterAdoption, before, "adoption must not type anything")
        let marker = try await tmux.sessionOption(
            AgentBinding.ownershipOptionName, target: existing.sessionID)
        XCTAssertNil(marker, "a session Marmy did not create is not marked")

        // Sending is a deliberate user action and still works.
        try await runtime.send("hello there", toNode: Team.workerID)
        try await waitForPane(existing.paneID, toContain: "hello there")
    }

    func testASameNameReplacementIsNotTypedInto() async throws {
        // An anchor keeps the private server alive: killing the last session
        // would end the server, and session ids start over on a new one.
        _ = try await startFixtureSession(named: "anchor")
        let serverBefore = try await tmux.serverIdentity()

        let runtime = try makeRuntime()
        let outcome = await runtime.launch(
            topology: topology, workspace: workspace, nodeIDs: [Team.workerID])
        let binding = try XCTUnwrap(outcome.started[Team.workerID])
        try await waitForPane(binding.paneID, toContain: "ARGS<")

        // The agent's session ends and something else claims the name.
        try await tmux.killSession(target: binding.sessionID)
        let replacement = try await startFixtureSession(named: "build")
        let serverAfter = try await tmux.serverIdentity()
        XCTAssertEqual(serverAfter, serverBefore, "the same server, so this is a session identity check")
        XCTAssertNotEqual(replacement.sessionID, binding.sessionID)
        let before = try await capture(replacement.paneID)

        do {
            try await runtime.send("this must not arrive", toNode: Team.workerID)
            XCTFail("expected the send to be refused")
        } catch let error as RuntimeError {
            guard case .identityMismatch = error else { return XCTFail("got \(error)") }
        }

        try await Task.sleep(nanoseconds: 300_000_000)
        let afterRefusal = try await capture(replacement.paneID)
        XCTAssertEqual(afterRefusal, before)

        let snapshot = try await runtime.snapshot(topology: topology)
        if case .missing = snapshot.state(of: Team.workerID) {} else {
            XCTFail("expected .missing, got \(snapshot.state(of: Team.workerID))")
        }
    }

    func testATerminalNodeStartsAShellAndIsSentNothing() async throws {
        // A shell node: no CLI, no prompt. The pane should be a live shell that
        // received no keystrokes at all.
        var team = topology
        team.nodes[1].cli = .terminal
        team.nodes[1].promptTemplateID = nil

        let runtime = try makeRuntime()
        let outcome = await runtime.launch(
            topology: team, workspace: workspace, nodeIDs: [Team.workerID])

        XCTAssertTrue(outcome.isFullSuccess, "\(outcome.failures) \(outcome.preflight.errors.map(\.message))")
        let binding = try XCTUnwrap(outcome.started[Team.workerID])

        // Give the shell a moment to draw a prompt, then look at what is there.
        try await Task.sleep(for: .seconds(1.5))
        let contents = try await capture(binding.paneID)
        XCTAssertFalse(contents.contains("You are"), "no role prompt was handed to a shell")
        XCTAssertFalse(contents.contains("Reaching other agents"))

        let panes = try await tmux.listPanes()
        let pane = try XCTUnwrap(panes.first { $0.id == binding.paneID })
        XCTAssertFalse(pane.isDead, "the shell is running")

        // And it answers as a shell does.
        try await runtime.send("echo marmy-shell-check", toNode: Team.workerID)
        try await waitForPane(binding.paneID, toContain: "marmy-shell-check")
    }

    func testForgettingANodeLeavesItsSessionRunning() async throws {
        let runtime = try makeRuntime()
        let outcome = await runtime.launch(
            topology: topology, workspace: workspace, nodeIDs: [Team.managerID])
        let binding = try XCTUnwrap(outcome.started[Team.managerID])

        _ = try await runtime.forget(nodeID: Team.managerID)
        let sessions = try await tmux.listSessions()
        XCTAssertTrue(sessions.contains { $0.id == binding.sessionID }, "sessions outlive the app's metadata")
    }

    func testAnAgentThatCannotStartIsReportedWithItsRealReason() async throws {
        // The CLI is replaced with something that is not executable, so the
        // trampoline fails and its pane disappears with it.
        let claude = environment.binDirectory.appendingPathComponent("claude")
        let runtime = try makeRuntime()
        let report = await runtime.preflight(topology: topology, workspace: workspace)
        XCTAssertFalse(report.isBlocked)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: claude.path)
        let outcome = await runtime.launch(
            topology: topology, workspace: workspace, nodeIDs: [Team.managerID])

        // Preflight catches it now that the file is no longer executable.
        XCTAssertTrue(outcome.preflight.isBlocked)
        XCTAssertTrue(outcome.preflight.errors.contains { $0.kind == .cliMissing(name: "claude") })
        let sessions = try await tmux.listSessions()
        XCTAssertTrue(sessions.isEmpty)
    }

    func testTheTrampolineReportsAFailureItCannotShowOnScreen() async throws {
        // Run the real helper directly: its pane would vanish, so the reason has
        // to survive in the error file the launcher reads.
        let trampoline = try realTrampoline()
        let spec = LaunchSpec(
            executablePath: "/nonexistent/claude",
            arguments: ["--", "hello"],
            workingDirectory: environment.workingDirectory.path,
            topologyID: Team.topologyID, nodeID: Team.managerID, generation: UUID())
        let specURL = try environment.store.writeSpec(spec)

        let result = try await runner.run(CommandInvocation(
            executable: trampoline.executablePath,
            arguments: trampoline.arguments(specPath: specURL.path)))

        XCTAssertEqual(result.exitCode, 70)
        let reported = try String(
            contentsOfFile: AgentTrampoline.errorPath(forSpecAt: specURL.path), encoding: .utf8)
        XCTAssertTrue(reported.contains("/nonexistent/claude"))
    }

    func testTheTrampolineEntersTheCLIWithTheSpecsEnvironmentAndCwd() async throws {
        // A fixture that reports what it inherited, then stays alive.
        try environment.writeExecutable(named: "claude", contents: """
        #!/bin/sh
        printf 'CWD<%s> CLAUDECODE<%s> TMUX<%s> ARG1<%s>\\n' "$(pwd)" "${CLAUDECODE-unset}" "${TMUX:+set}" "$1"
        exec /bin/cat
        """)
        let runtime = try makeRuntime()
        let outcome = await runtime.launch(
            topology: topology, workspace: workspace, nodeIDs: [Team.managerID])
        let binding = try XCTUnwrap(outcome.started[Team.managerID])

        let contents = try await waitForPane(binding.paneID, toContain: "CWD<")
        XCTAssertTrue(contents.contains(environment.workingDirectory.resolvingSymlinksInPath().lastPathComponent))
        XCTAssertTrue(contents.contains("CLAUDECODE<unset>"), "an inherited CLAUDECODE is dropped")
        XCTAssertTrue(contents.contains("TMUX<set>"), "the pane's own TMUX is kept so the agent can address tmux")
        XCTAssertTrue(contents.contains("ARG1<-->"), "the prompt follows an end-of-options marker")
    }

    func testSpecFilesAreCleanedUpAfterASuccessfulStart() async throws {
        let runtime = try makeRuntime()
        _ = await runtime.launch(topology: topology, workspace: workspace, nodeIDs: [Team.managerID])

        let remaining = (try? FileManager.default.contentsOfDirectory(
            atPath: environment.store.specsDirectoryURL.path)) ?? []
        XCTAssertTrue(remaining.isEmpty, "left behind: \(remaining)")
    }
}
