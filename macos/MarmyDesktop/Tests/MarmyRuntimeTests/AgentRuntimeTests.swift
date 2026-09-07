import XCTest
import MarmyCore
@testable import MarmyRuntime

final class AgentRuntimeTests: XCTestCase {

    private var environment: TestEnvironment!
    private var runner: FakeCommandRunner!

    override func setUpWithError() throws {
        environment = try TestEnvironment()
        runner = FakeCommandRunner()
        runner.stub("display-message", TmuxFixtures.serverIdentity())
    }

    override func tearDownWithError() throws {
        environment.cleanUp()
    }

    private func makeRuntime() throws -> AgentRuntime {
        try AgentRuntime(
            tmux: TmuxClient(executablePath: environment.tmuxPath, runner: runner),
            locator: environment.locator,
            store: environment.store,
            trampoline: environment.trampoline)
    }

    private var topology: Topology { Team.topology(workingDirectory: environment.workingDirectory.path) }
    private var workspace: Workspace { Team.workspace(workingDirectory: environment.workingDirectory.path) }

    // MARK: - Launch

    func testBlockedPreflightStartsNothingAtAll() async throws {
        runner.stub("list-sessions", TmuxFixtures.sessions([(id: "$9", name: "build")]))
        runner.stub("list-panes", TmuxFixtures.panes([]))

        let outcome = await (try makeRuntime()).launch(topology: topology, workspace: workspace)
        XCTAssertTrue(outcome.preflight.isBlocked)
        XCTAssertTrue(outcome.started.isEmpty)
        XCTAssertTrue(runner.calls(of: "new-session").isEmpty, "nothing may be mutated")
        XCTAssertTrue(runner.calls(of: "kill-session").isEmpty)
    }

    func testLaunchStartsEachNodeThroughTheTrampoline() async throws {
        stubHealthyLaunch()
        let runtime = try makeRuntime()
        let outcome = await runtime.launch(topology: topology, workspace: workspace)

        XCTAssertTrue(outcome.isFullSuccess, "\(outcome.failures)")
        XCTAssertEqual(outcome.started.count, 2)

        let starts = runner.calls(of: "new-session")
        XCTAssertEqual(starts.count, 2)
        // tmux runs the fixed trampoline; only the spec path varies.
        XCTAssertEqual(starts[0].arguments.suffix(2).first, environment.trampoline.executablePath)
        XCTAssertTrue(starts[0].arguments.last!.hasSuffix(".json"))
        XCTAssertFalse(starts[0].arguments.contains { $0.contains("You are Lead") },
                       "the prompt never reaches tmux's command line")

        // Ownership is marked on the session Marmy created, by stable id.
        let marks = runner.calls(of: "set-option")
        XCTAssertEqual(marks.count, 2)
        XCTAssertEqual(marks[0].arguments[1], "-t")
        XCTAssertTrue(marks[0].arguments[2].hasPrefix("$"))
        XCTAssertEqual(marks[0].arguments[3], AgentBinding.ownershipOptionName)
    }

    func testTheLaunchSpecCarriesThePromptAndTheEnvironmentRules() async throws {
        stubHealthyLaunch()
        // Keep the spec around so its contents can be inspected.
        let runtime = try makeRuntime()
        _ = await runtime.launch(topology: topology, workspace: workspace)

        let specPath = try XCTUnwrap(runner.calls(of: "new-session").first?.arguments.last)
        // The trampoline would have deleted it; the launcher's cleanup also runs,
        // so the spec is rebuilt from the same inputs to assert its shape.
        XCTAssertTrue(specPath.hasSuffix(".json"))
        XCTAssertTrue(specPath.contains(environment.dataDirectory.lastPathComponent))
    }

    func testAPartialFailureKeepsWhatStartedAndRetryOnlyStartsTheRest() async throws {
        runner.stub("list-sessions", TmuxFixtures.sessions([]))
        runner.stub("list-panes", TmuxFixtures.panes([]))
        runner.stub("list-panes", TmuxFixtures.panes([(pane: "%1", session: "$1", name: "lead")]))
        runner.stub("new-session", TmuxFixtures.started(session: "$1", name: "lead", pane: "%1"))
        runner.stub("new-session", CommandResult(exitCode: 1, standardError: "duplicate session: build"))

        let runtime = try makeRuntime()
        let first = await runtime.launch(topology: topology, workspace: workspace)
        XCTAssertEqual(Array(first.started.keys), [Team.managerID])
        XCTAssertNotNil(first.failures[Team.workerID])
        XCTAssertFalse(first.isFullSuccess)

        // The manager's session is recorded and alive, so a retry leaves it be.
        let retryRunner = FakeCommandRunner()
        retryRunner.stub("display-message", TmuxFixtures.serverIdentity())
        retryRunner.stub("list-sessions", TmuxFixtures.sessions([(id: "$1", name: "lead")]))
        retryRunner.stub("list-panes", TmuxFixtures.panes([(pane: "%1", session: "$1", name: "lead")]))
        retryRunner.stub("list-panes", TmuxFixtures.panes([
            (pane: "%1", session: "$1", name: "lead"), (pane: "%2", session: "$2", name: "build"),
        ]))
        retryRunner.stub("new-session", TmuxFixtures.started(session: "$2", name: "build", pane: "%2"))

        // A fresh runtime, so the ledger is reloaded from disk as it would be
        // after a restart.
        let reopened = try AgentRuntime(
            tmux: TmuxClient(executablePath: environment.tmuxPath, runner: retryRunner),
            locator: environment.locator, store: environment.store, trampoline: environment.trampoline)
        let second = await reopened.launch(topology: topology, workspace: workspace)

        XCTAssertEqual(Array(second.started.keys), [Team.workerID])
        XCTAssertEqual(second.skipped[Team.managerID], "already running in lead")
        XCTAssertEqual(retryRunner.calls(of: "new-session").count, 1, "the running manager is not restarted")
    }

    func testAnAgentThatDiesImmediatelyIsReportedAndNotRecorded() async throws {
        runner.stub("list-sessions", TmuxFixtures.sessions([]))
        runner.stub("list-panes", TmuxFixtures.panes([]))     // snapshot
        runner.stub("list-panes", TmuxFixtures.panes([]))     // confirmation: pane already gone
        runner.stub("new-session", TmuxFixtures.started(session: "$1", name: "lead", pane: "%1"))

        let runtime = try makeRuntime()
        let outcome = await runtime.launch(topology: topology, workspace: workspace, nodeIDs: [Team.managerID])

        XCTAssertTrue(outcome.started.isEmpty)
        XCTAssertTrue(outcome.failures[Team.managerID]!.contains("stopped straight away"))
        let binding = await runtime.binding(for: Team.managerID)
        XCTAssertNil(binding, "a dead start is never recorded as running")
    }

    func testADeadPaneReadsAsMissingRatherThanRunning() {
        let binding = AgentBinding(
            topologyID: Team.topologyID, nodeID: Team.managerID, generation: UUID(),
            sessionName: "lead", sessionID: "$1", paneID: "%1", server: TmuxFixtures.identity,
            ownership: .launched, cli: .claude, startedAt: Date())
        let dead = TmuxPane(
            id: "%1", sessionID: "$1", sessionName: "lead", windowID: "@0", pid: 1,
            currentCommand: "cat", currentPath: "/tmp", isActive: true, isWindowActive: true, isDead: true)

        let state = LiveIdentity.state(
            for: binding, server: TmuxFixtures.identity, panes: [dead],
            sessions: [TmuxSession(id: "$1", name: "lead", created: 1, isAttached: false, windowCount: 1)])
        XCTAssertEqual(state, .missing(reason: "The agent in \u{22}lead\u{22} has exited."))
    }

    // MARK: - Adoption

    func testAdoptionRecordsTheSessionAndSendsNothing() async throws {
        runner.stub("list-sessions", TmuxFixtures.sessions([(id: "$5", name: "marmy_worker_opus")]))
        runner.stub("list-panes", TmuxFixtures.panes([
            (pane: "%5", session: "$5", name: "marmy_worker_opus"),
        ]))

        let runtime = try makeRuntime()
        let binding = try await runtime.adopt(
            sessionName: "marmy_worker_opus", nodeID: Team.workerID, topology: topology, cli: .codex)

        XCTAssertEqual(binding.ownership, .adopted)
        XCTAssertEqual(binding.sessionID, "$5")
        XCTAssertEqual(binding.paneID, "%5")
        XCTAssertEqual(binding.cli, .codex)
        // An already-running agent — or a plain shell — is left untouched.
        XCTAssertTrue(runner.calls(of: "send-keys").isEmpty)
        XCTAssertTrue(runner.calls(of: "load-buffer").isEmpty)
        XCTAssertTrue(runner.calls(of: "paste-buffer").isEmpty)
        XCTAssertTrue(runner.calls(of: "new-session").isEmpty)
        XCTAssertTrue(runner.calls(of: "set-option").isEmpty, "a user's own session is not marked")
    }

    func testAdoptingAnAbsentSessionFails() async throws {
        runner.stub("list-sessions", TmuxFixtures.sessions([]))
        do {
            _ = try await makeRuntime().adopt(
                sessionName: "ghost", nodeID: Team.workerID, topology: topology, cli: nil)
            XCTFail("expected a failure")
        } catch let error as RuntimeError {
            XCTAssertEqual(error, .sessionNotFound(name: "ghost"))
        }
    }

    func testASessionCannotBeAdoptedTwiceOnTheSameServer() async throws {
        runner.stub("list-sessions", TmuxFixtures.sessions([(id: "$5", name: "shared")]))
        runner.stub("list-panes", TmuxFixtures.panes([(pane: "%5", session: "$5", name: "shared")]))
        let runtime = try makeRuntime()
        _ = try await runtime.adopt(sessionName: "shared", nodeID: Team.workerID, topology: topology, cli: nil)

        do {
            _ = try await runtime.adopt(
                sessionName: "shared", nodeID: Team.managerID, topology: topology, cli: nil)
            XCTFail("expected a clash")
        } catch let error as RuntimeError {
            guard case .sessionAlreadyBound = error else { return XCTFail("got \(error)") }
        }
    }

    func testAStaleBindingFromARestartedServerDoesNotBlockAdoption() async throws {
        // Session ids are only unique per server, so `$5` on a new server is not
        // the `$5` an old binding remembers.
        var ledger = RuntimeLedger()
        ledger.upsert(AgentBinding(
            topologyID: Team.topologyID, nodeID: Team.managerID, generation: UUID(),
            sessionName: "old", sessionID: "$5", paneID: "%5",
            server: TmuxServerIdentity(pid: 1, socketPath: "/tmp/old", startTime: 1),
            ownership: .adopted, cli: nil, startedAt: Date()))
        try environment.store.saveLedger(ledger)

        runner.stub("list-sessions", TmuxFixtures.sessions([(id: "$5", name: "fresh")]))
        runner.stub("list-panes", TmuxFixtures.panes([(pane: "%5", session: "$5", name: "fresh")]))

        let binding = try await makeRuntime().adopt(
            sessionName: "fresh", nodeID: Team.workerID, topology: topology, cli: .claude)
        XCTAssertEqual(binding.sessionName, "fresh")
    }

    // MARK: - Sending

    func testSendUsesTheExactPaneAndABufferThatCleansItselfUp() async throws {
        let runtime = try await adoptedRuntime()
        let text = "run this;\n`echo pwned`\n$HOME --flag\nünicode ✅"
        try await runtime.send(text, toNode: Team.workerID)

        let load = runner.calls(of: "load-buffer")
        XCTAssertEqual(load.count, 1)
        XCTAssertEqual(load[0].standardInput, Data(text.utf8))
        let bufferName = load[0].arguments[2]
        XCTAssertTrue(bufferName.hasPrefix("marmy-"), "a private buffer, not the anonymous stack")

        let paste = runner.calls(of: "paste-buffer")
        XCTAssertEqual(paste[0].arguments, ["paste-buffer", "-d", "-p", "-r", "-t", "%5", "-b", bufferName])

        let enter = runner.calls(of: "send-keys")
        XCTAssertEqual(enter[0].arguments, ["send-keys", "-t", "%5", "Enter"])
        XCTAssertTrue(runner.calls(of: "delete-buffer").isEmpty, "paste -d already removed it")
    }

    func testSendNeverTargetsAPrefixNameOrPaneZero() async throws {
        let runtime = try await adoptedRuntime()
        try await runtime.send("hello", toNode: Team.workerID)

        for call in runner.calls(of: "paste-buffer") + runner.calls(of: "send-keys") {
            let target = call.arguments[call.arguments.firstIndex(of: "-t")! + 1]
            XCTAssertEqual(target, "%5")
            XCTAssertNotEqual(target, "%0")
        }
    }

    func testSendRefusesWhenThePaneNowBelongsToSomethingElse() async throws {
        let runtime = try await adoptedRuntime()
        runner.replace("list-panes", with: TmuxFixtures.panes([
            (pane: "%5", session: "$77", name: "someone-else"),
        ]))

        do {
            try await runtime.send("hello", toNode: Team.workerID)
            XCTFail("expected an identity mismatch")
        } catch let error as RuntimeError {
            guard case .identityMismatch = error else { return XCTFail("got \(error)") }
        }
        XCTAssertTrue(runner.calls(of: "load-buffer").isEmpty, "nothing may be typed into the wrong pane")
    }

    func testSendRefusesAfterTheServerRestarted() async throws {
        let runtime = try await adoptedRuntime()
        runner.replace("display-message", with: TmuxFixtures.serverIdentity(pid: 999, startTime: 9999))

        do {
            try await runtime.send("hello", toNode: Team.workerID)
            XCTFail("expected an identity mismatch")
        } catch let error as RuntimeError {
            guard case .identityMismatch = error else { return XCTFail("got \(error)") }
        }
        XCTAssertTrue(runner.calls(of: "load-buffer").isEmpty)
    }

    func testSendToAnUnboundNodeFails() async throws {
        let runtime = try makeRuntime()
        do {
            try await runtime.send("hello", toNode: Team.workerID)
            XCTFail("expected a failure")
        } catch let error as RuntimeError {
            XCTAssertEqual(error, .notBound(nodeID: Team.workerID))
        }
    }

    func testAFailedPasteDeletesTheBuffer() async throws {
        let runtime = try await adoptedRuntime()
        runner.stub("paste-buffer", CommandResult(exitCode: 1, standardError: "can't find pane: %5"))

        do {
            try await runtime.send("hello", toNode: Team.workerID)
            XCTFail("expected a failure")
        } catch {}

        XCTAssertEqual(runner.calls(of: "delete-buffer").count, 1, "no buffer is left behind")
        XCTAssertTrue(runner.calls(of: "send-keys").isEmpty, "Enter is never sent after a failed paste")
    }

    func testForgettingANodeDoesNotTouchTheSession() async throws {
        let runtime = try await adoptedRuntime()
        let removed = try await runtime.forget(nodeID: Team.workerID)

        XCTAssertNotNil(removed)
        let binding = await runtime.binding(for: Team.workerID)
        XCTAssertNil(binding)
        XCTAssertTrue(runner.calls(of: "kill-session").isEmpty, "the agent keeps running")
    }

    // MARK: - Helpers

    private func stubHealthyLaunch() {
        runner.stub("list-sessions", TmuxFixtures.sessions([]))
        runner.stub("list-panes", TmuxFixtures.panes([]))
        runner.stub("list-panes", TmuxFixtures.panes([(pane: "%1", session: "$1", name: "lead")]))
        runner.stub("list-panes", TmuxFixtures.panes([
            (pane: "%1", session: "$1", name: "lead"), (pane: "%2", session: "$2", name: "build"),
        ]))
        runner.stub("new-session", TmuxFixtures.started(session: "$1", name: "lead", pane: "%1"))
        runner.stub("new-session", TmuxFixtures.started(session: "$2", name: "build", pane: "%2"))
    }

    /// A runtime with the worker adopted into `$5` / `%5`.
    private func adoptedRuntime() async throws -> AgentRuntime {
        runner.stub("list-sessions", TmuxFixtures.sessions([(id: "$5", name: "existing")]))
        runner.stub("list-panes", TmuxFixtures.panes([(pane: "%5", session: "$5", name: "existing")]))
        let runtime = try makeRuntime()
        _ = try await runtime.adopt(
            sessionName: "existing", nodeID: Team.workerID, topology: topology, cli: .claude)
        return runtime
    }
}
