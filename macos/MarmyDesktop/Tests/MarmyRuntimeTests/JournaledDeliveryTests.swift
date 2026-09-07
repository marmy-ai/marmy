import XCTest
import MarmyCore
@testable import MarmyRuntime

/// Sending something Marmy has written down, and recording what became of it.
///
/// Nothing here talks to a real tmux server: the commands are answered by a
/// fake, so the failure halves — a write that does not land, a pane that has
/// been relaunched, two sends racing — can be exercised at all.
final class JournaledDeliveryTests: XCTestCase {

    private var environment: TestEnvironment!
    private var runner: FakeCommandRunner!

    override func setUpWithError() throws {
        environment = try TestEnvironment()
        runner = FakeCommandRunner()
        runner.stub("display-message", TmuxFixtures.serverIdentity())
        runner.stub("list-sessions", TmuxFixtures.sessions([(id: "$1", name: "lead")]))
        runner.stub("list-panes", TmuxFixtures.panes([(pane: "%1", session: "$1", name: "lead")]))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: environment.store.directoryURL.path)
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

    /// A runtime with the manager adopted into `$1` / `%1`, and the target that
    /// names it.
    private func adopted() async throws -> (AgentRuntime, AgentRuntime.DeliveryTarget) {
        let runtime = try makeRuntime()
        let binding = try await runtime.adopt(
            sessionName: "lead", nodeID: Team.managerID, topology: topology, cli: .claude)
        let identity = try await runtime.tmux.serverIdentity()
        let server = try XCTUnwrap(identity)
        return (runtime, AgentRuntime.DeliveryTarget(
            sessionID: binding.sessionID, paneID: binding.paneID, server: server,
            generation: binding.generation))
    }

    // MARK: - One send, once

    func testAMessageIsRecordedBeforeItIsSent() async throws {
        let (runtime, target) = try await adopted()
        let entry = try await runtime.recordPrepared(
            "the team as it stands", kind: .rosterUpdate, toNode: Team.managerID,
            topologyID: topology.id, expecting: target)

        XCTAssertEqual(entry.status, .prepared)
        XCTAssertTrue(runner.calls(of: "paste-buffer").isEmpty, "nothing goes before it is written down")

        let sent = try await runtime.sendPrepared(entry, expecting: target, delivery: .submit)
        XCTAssertEqual(sent.status, .submitted)
        XCTAssertEqual(sent.payload, "the team as it stands", "exactly what was handed over")
        XCTAssertEqual(runner.calls(of: "paste-buffer").count, 1)
        XCTAssertEqual(runner.calls(of: "send-keys").count, 1, "submitted means Return, once")
    }

    func testTheSameMessageCannotBeSentTwice() async throws {
        let (runtime, target) = try await adopted()
        let entry = try await runtime.recordPrepared(
            "once only", kind: .rosterUpdate, toNode: Team.managerID,
            topologyID: topology.id, expecting: target)

        _ = try await runtime.sendPrepared(entry, expecting: target, delivery: .submit)
        await XCTAssertThrowsErrorAsync(
            try await runtime.sendPrepared(entry, expecting: target, delivery: .submit))

        XCTAssertEqual(runner.calls(of: "paste-buffer").count, 1, "the agent hears it once")
    }

    func testTwoSendsOfTheSameMessageAtOnceOnlyDeliverItOnce() async throws {
        let (runtime, target) = try await adopted()
        let entry = try await runtime.recordPrepared(
            "at the same time", kind: .rosterUpdate, toNode: Team.managerID,
            topologyID: topology.id, expecting: target)

        async let first: JournalEntry? = try? await runtime.sendPrepared(
            entry, expecting: target, delivery: .submit)
        async let second: JournalEntry? = try? await runtime.sendPrepared(
            entry, expecting: target, delivery: .submit)
        let results = [await first, await second]

        XCTAssertEqual(results.compactMap { $0 }.count, 1, "one of them found it already dealt with")
        XCTAssertEqual(runner.calls(of: "paste-buffer").count, 1)
    }

    func testAMessageRecordedForAnotherTerminalIsRefused() async throws {
        let (runtime, target) = try await adopted()
        let entry = try await runtime.recordPrepared(
            "for the old launch", kind: .rosterUpdate, toNode: Team.managerID,
            topologyID: topology.id, expecting: target)

        // The agent has been started again since: same pane, new launch.
        var relaunched = target
        relaunched.generation = UUID()

        await XCTAssertThrowsErrorAsync(
            try await runtime.sendPrepared(entry, expecting: relaunched, delivery: .submit))
        XCTAssertTrue(runner.calls(of: "paste-buffer").isEmpty)
    }

    // MARK: - When the record cannot be kept

    func testAMessageThatCannotBeWrittenDownIsNotSent() async throws {
        let (runtime, target) = try await adopted()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: environment.store.directoryURL.path)

        await XCTAssertThrowsErrorAsync(try await runtime.recordPrepared(
            "unrecordable", kind: .rosterUpdate, toNode: Team.managerID,
            topologyID: topology.id, expecting: target))

        XCTAssertTrue(runner.calls(of: "paste-buffer").isEmpty,
                      "an agent told something Marmy cannot account for is worse than silence")
    }

    func testADeliveryWhoseOutcomeCannotBeWrittenIsUncertainNotFailed() async throws {
        let (runtime, target) = try await adopted()
        let entry = try await runtime.recordPrepared(
            "it went, the record did not", kind: .rosterUpdate, toNode: Team.managerID,
            topologyID: topology.id, expecting: target)

        // The disk goes away in the middle of the delivery: the paste has gone
        // out, and the record of it going cannot be written.
        let directory = environment.store.directoryURL.path
        runner.beforeCall = { call in
            guard call.subcommand == "send-keys" else { return }
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o500], ofItemAtPath: directory)
        }

        do {
            _ = try await runtime.sendPrepared(entry, expecting: target, delivery: .submit)
            XCTFail("expected an uncertain delivery")
        } catch let error as RuntimeError {
            guard case .deliveryUncertain = error else {
                return XCTFail("expected uncertainty, got \(error)")
            }
        }
    }

    func testAMessageWhoseAttemptCannotBeRecordedNeverLeaves() async throws {
        let (runtime, target) = try await adopted()
        let entry = try await runtime.recordPrepared(
            "not even attempted", kind: .rosterUpdate, toNode: Team.managerID,
            topologyID: topology.id, expecting: target)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: environment.store.directoryURL.path)

        await XCTAssertThrowsErrorAsync(
            try await runtime.sendPrepared(entry, expecting: target, delivery: .submit))

        XCTAssertTrue(runner.calls(of: "paste-buffer").isEmpty,
                      "an attempt Marmy cannot record is an attempt it does not make")
    }

    func testAFailedPasteLeavesTheMessageWaitingRatherThanLost() async throws {
        let (runtime, target) = try await adopted()
        let entry = try await runtime.recordPrepared(
            "did not go", kind: .rosterUpdate, toNode: Team.managerID,
            topologyID: topology.id, expecting: target)
        runner.stub("load-buffer", CommandResult(exitCode: 1, standardError: "no space"))

        await XCTAssertThrowsErrorAsync(
            try await runtime.sendPrepared(entry, expecting: target, delivery: .submit))

        let stored = try await runtime.journal.entry(id: entry.id)
        XCTAssertEqual(stored?.status, .failed)
        XCTAssertEqual(stored?.payload, "did not go", "the words are kept")
    }

    // MARK: - Replacing and retrying

    func testOnlyAMessageThatWasNeverTriedCanBeSuperseded() async throws {
        let (runtime, target) = try await adopted()
        let waiting = try await runtime.recordPrepared(
            "still waiting", kind: .rosterUpdate, toNode: Team.managerID,
            topologyID: topology.id, expecting: target)
        let sent = try await runtime.recordPrepared(
            "already gone", kind: .rosterUpdate, toNode: Team.managerID,
            topologyID: topology.id, expecting: target)
        _ = try await runtime.sendPrepared(sent, expecting: target, delivery: .submit)

        let replacedWaiting = await runtime.supersede(waiting, reason: "newer one")
        let replacedSent = await runtime.supersede(sent, reason: "newer one")

        XCTAssertTrue(replacedWaiting)
        XCTAssertFalse(replacedSent, "what an agent was told is not rewritten afterwards")
        let stored = try await runtime.journal.entry(id: sent.id)
        XCTAssertEqual(stored?.status, .submitted)
    }

    func testARetryIsANewAttemptThatKeepsTheOldOne() async throws {
        let (runtime, target) = try await adopted()
        let first = try await runtime.recordPrepared(
            "hello", kind: .rosterUpdate, toNode: Team.managerID,
            topologyID: topology.id, expecting: target)

        var relaunched = target
        relaunched.generation = UUID()
        let retry = try await runtime.prepareRetry(of: first, expecting: relaunched)

        XCTAssertNotEqual(retry.id, first.id)
        XCTAssertEqual(retry.previousAttemptID, first.id)
        XCTAssertEqual(retry.payload, first.payload)
        let old = try await runtime.journal.entry(id: first.id)
        XCTAssertEqual(old?.status, .superseded)
        XCTAssertEqual(old?.generation, target.generation, "the old attempt keeps its own recipient")
    }

    // MARK: - Starting prompts

    func testALaunchPromptIsWrittenDownBeforeTheAgentStarts() async throws {
        runner.replace("list-sessions", with: TmuxFixtures.sessions([]))
        runner.replace("list-panes", with: TmuxFixtures.panes([]))
        runner.stub("list-panes", TmuxFixtures.panes([(pane: "%1", session: "$1", name: "lead")]))
        runner.stub("list-panes", TmuxFixtures.panes([
            (pane: "%1", session: "$1", name: "lead"), (pane: "%2", session: "$2", name: "build"),
        ]))
        runner.stub("new-session", TmuxFixtures.started(session: "$1", name: "lead", pane: "%1"))
        runner.stub("new-session", TmuxFixtures.started(session: "$2", name: "build", pane: "%2"))

        let runtime = try makeRuntime()
        let outcome = await runtime.launch(
            topology: topology, workspace: Team.workspace(
                workingDirectory: environment.workingDirectory.path))
        XCTAssertTrue(outcome.isFullSuccess, "\(outcome.failures)")

        let entries = try await runtime.journal.all().filter { $0.kind == .launchPrompt }
        XCTAssertEqual(entries.count, 2, "what each agent was started with")
        let lead = try XCTUnwrap(entries.first { $0.nodeID == Team.managerID })
        XCTAssertEqual(lead.status, .submitted)
        XCTAssertTrue(lead.payload.contains("Lead"), "the prompt itself, not a re-render")
        XCTAssertEqual(lead.paneID, "%1", "and where it went, recorded with the outcome")
        XCTAssertEqual(lead.sessionID, "$1")
        XCTAssertNotNil(lead.serverPID, "a session id means nothing without its server")
        XCTAssertNotNil(lead.generation)
    }

    func testAnAgentThatDoesNotStayRunningLeavesAnUncertainPromptNotAFailedOne() async throws {
        // tmux makes the pane, and the program in it is gone a moment later. The
        // prompt went with the process, so whether it was read is not knowable.
        runner.replace("list-sessions", with: TmuxFixtures.sessions([]))
        runner.replace("list-panes", with: TmuxFixtures.panes([]))
        runner.stub("list-panes", TmuxFixtures.panes(
            [(pane: "%1", session: "$1", name: "lead")], dead: true))
        runner.stub("new-session", TmuxFixtures.started(session: "$1", name: "lead", pane: "%1"))

        let runtime = try makeRuntime()
        let outcome = await runtime.launch(
            topology: topology, workspace: Team.workspace(
                workingDirectory: environment.workingDirectory.path),
            nodeIDs: [Team.managerID])
        XCTAssertFalse(outcome.failures.isEmpty, "the launch itself did fail")

        let all = try await runtime.journal.all()
        let entry = try XCTUnwrap(all.first { $0.kind == .launchPrompt })
        XCTAssertEqual(entry.status, .uncertain,
                       "the process had the prompt; nobody can say whether it read it")
        XCTAssertEqual(entry.paneID, "%1", "and the pane it was started in is on record")
        XCTAssertTrue(entry.detail?.contains("not known") == true)
    }

    func testALaunchWhoseRecordCannotBeFinishedStillKeepsTheAgentAndSaysSo() async throws {
        runner.replace("list-sessions", with: TmuxFixtures.sessions([]))
        runner.replace("list-panes", with: TmuxFixtures.panes([]))
        runner.stub("list-panes", TmuxFixtures.panes([(pane: "%1", session: "$1", name: "lead")]))
        runner.stub("new-session", TmuxFixtures.started(session: "$1", name: "lead", pane: "%1"))

        // The prompt is recorded and marked as being sent, and then the file it
        // lives in becomes unwritable — after the agent has been spawned with
        // the prompt in hand.
        let journalPath = environment.store.directoryURL
            .appendingPathComponent(MessageJournal.fileName).path
        runner.beforeCall = { call in
            guard call.subcommand == "new-session" else { return }
            try? FileManager.default.removeItem(atPath: journalPath)
            try? FileManager.default.createDirectory(
                atPath: journalPath, withIntermediateDirectories: false)
        }

        let runtime = try makeRuntime()
        let outcome = await runtime.launch(
            topology: topology, workspace: Team.workspace(
                workingDirectory: environment.workingDirectory.path),
            nodeIDs: [Team.managerID])
        runner.beforeCall = nil

        XCTAssertTrue(outcome.failures.isEmpty, "the agent is running; that is not a failure")
        XCTAssertNotNil(outcome.started[Team.managerID], "and its session is kept")
        let warning = try XCTUnwrap(outcome.warnings[Team.managerID],
                                    "a silent success would be a lie about the history")
        XCTAssertTrue(warning.contains("could not record"))
        XCTAssertTrue(warning.contains("unconfirmed"))

        let recorded = try await runtime.journal.all()
        let entry = try XCTUnwrap(recorded.first { $0.kind == .launchPrompt })
        XCTAssertEqual(entry.status, .sending, "which is what an unconfirmed delivery looks like")
        XCTAssertTrue(entry.payload.contains("Lead"), "the prompt itself is still on record")
    }

    func testAPromptThatCannotBeWrittenDownStopsTheLaunch() async throws {
        runner.replace("list-sessions", with: TmuxFixtures.sessions([]))
        runner.replace("list-panes", with: TmuxFixtures.panes([]))
        runner.stub("new-session", TmuxFixtures.started(session: "$1", name: "lead", pane: "%1"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: environment.store.directoryURL.path)

        let runtime = try makeRuntime()
        let outcome = await runtime.launch(
            topology: topology, workspace: Team.workspace(
                workingDirectory: environment.workingDirectory.path),
            nodeIDs: [Team.managerID])

        XCTAssertTrue(outcome.started.isEmpty)
        XCTAssertTrue(runner.calls(of: "new-session").isEmpty,
                      "an agent holding instructions Marmy has no record of is worse than none")
    }
}
