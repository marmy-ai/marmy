import XCTest
import MarmyCore
@testable import MarmyRuntime

/// Sending to a pane the user has scrolled back.
///
/// In copy mode a pasted buffer still reaches the agent, but tmux swallows the
/// Return that would send it — the fixture that found this got
/// `ROSTER FIXTURE` with no carriage return. Half a message in a prompt nobody
/// can see is worse than a message that waits.
final class CopyModeDeliveryTests: XCTestCase {

    private var environment: TestEnvironment!
    private var runner: FakeCommandRunner!

    override func setUpWithError() throws {
        environment = try TestEnvironment()
        runner = FakeCommandRunner()
        runner.stub("display-message", TmuxFixtures.serverIdentity())
        runner.stub("list-sessions", TmuxFixtures.sessions([(id: "$1", name: "lead")]))
        runner.stub("list-panes", TmuxFixtures.panes([(pane: "%1", session: "$1", name: "lead")]))
        // The pane is scrolled back, reading earlier output.
        runner.respond = { call in
            guard call.subcommand == "display-message",
                  call.arguments.contains(where: { $0.contains("pane_in_mode") })
            else { return nil }
            return CommandResult(exitCode: 0, standardOutput: "copy-mode\n")
        }
    }

    override func tearDownWithError() throws {
        environment.cleanUp()
    }

    private var topology: Topology { Team.topology(workingDirectory: environment.workingDirectory.path) }

    private func adopted() async throws -> (AgentRuntime, AgentRuntime.DeliveryTarget) {
        let runtime = try AgentRuntime(
            tmux: TmuxClient(executablePath: environment.tmuxPath, runner: runner),
            locator: environment.locator,
            store: environment.store,
            trampoline: environment.trampoline)
        let binding = try await runtime.adopt(
            sessionName: "lead", nodeID: Team.managerID, topology: topology, cli: .claude)
        let identity = try await runtime.tmux.serverIdentity()
        let server = try XCTUnwrap(identity)
        return (runtime, AgentRuntime.DeliveryTarget(
            sessionID: binding.sessionID, paneID: binding.paneID, server: server,
            generation: binding.generation))
    }

    /// Every copy-mode command sent, in order, so "cancel" can be told from the
    /// Return that sends a message.
    private func keys() -> [String] {
        runner.calls.compactMap { call in
            guard call.subcommand == "send-keys" else { return nil }
            return call.arguments.last
        }
    }

    func testAnAutomaticUpdateWaitsWhileTheUserIsReadingEarlierOutput() async throws {
        let (runtime, target) = try await adopted()
        let entry = try await runtime.recordPrepared(
            "the team as it stands", kind: .rosterUpdate, toNode: Team.managerID,
            topologyID: topology.id, expecting: target)

        do {
            _ = try await runtime.sendPrepared(
                entry, expecting: target, delivery: .submit, requireIdle: true, in: topology)
            XCTFail("expected the update to wait")
        } catch let error as RuntimeError {
            guard case .agentBusy(let detail) = error else {
                return XCTFail("expected it to wait, got \(error)")
            }
            XCTAssertTrue(detail.contains("earlier output"), detail)
        }

        XCTAssertTrue(runner.calls(of: "load-buffer").isEmpty, "nothing was loaded")
        XCTAssertTrue(runner.calls(of: "paste-buffer").isEmpty, "and nothing was pasted")
        XCTAssertTrue(keys().isEmpty, "no Return, and the scrollback was left alone")

        let stored = try await runtime.journal.entry(id: entry.id)
        XCTAssertEqual(stored?.status, .prepared, "it is still waiting to be sent")
        XCTAssertEqual(stored?.payload, "the team as it stands")
    }

    func testSendingItByHandComesBackToThePromptFirst() async throws {
        let (runtime, target) = try await adopted()
        let entry = try await runtime.recordPrepared(
            "sent on purpose", kind: .rosterUpdate, toNode: Team.managerID,
            topologyID: topology.id, expecting: target)

        // What "Send now" does: the user asked, so it has to arrive whole.
        let sent = try await runtime.sendPrepared(
            entry, expecting: target, delivery: .submit, requireIdle: false, in: topology)

        XCTAssertEqual(sent.status, .submitted)
        XCTAssertEqual(keys(), ["cancel", "Enter"],
                       "back to the prompt before the message, and the Return after it")
        let order = runner.subcommands.filter {
            ["send-keys", "load-buffer", "paste-buffer"].contains($0)
        }
        XCTAssertEqual(order, ["send-keys", "load-buffer", "paste-buffer", "send-keys"],
                       "the pane left copy mode before anything was pasted into it")
    }
}
