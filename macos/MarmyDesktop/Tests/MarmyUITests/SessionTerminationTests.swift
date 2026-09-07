import XCTest
import MarmyCore
import MarmyRuntime
@testable import MarmyUI

/// Stopping tmux sessions, which stops whatever is running inside them.
/// What a private tmux would still list, as sessions are stopped.
private final class SessionList: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [String]

    init(sessions: [String]) { remaining = sessions }

    var ids: [String] {
        lock.lock(); defer { lock.unlock() }
        return remaining
    }

    func remove(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        remaining.removeAll { $0 == id }
    }
}

@MainActor
final class SessionTerminationTests: XCTestCase {

    private var bench: TestBench!
    private var env: AppEnvironment { bench.env }

    override func setUpWithError() throws {
        bench = try TestBench()
    }

    override func tearDownWithError() throws {
        bench.cleanUp()
    }

    private var manager: AgentNode { bench.topology.roots[0] }

    // MARK: - What the question is about

    func testTheQuestionNamesTheSessionsThatAreActuallyRunning() async throws {
        try await bench.bindEverything()

        env.requestDeletion(of: bench.topology)

        let plan = try XCTUnwrap(env.pendingTermination)
        XCTAssertEqual(plan.topology?.id, bench.topology.id)
        XCTAssertEqual(plan.sessions.count, bench.topology.nodes.count)
        for node in bench.topology.nodes {
            XCTAssertTrue(
                plan.sessions.contains { $0.agents.contains(node.displayName) },
                "\(node.displayName) is running somewhere and the question should say where")
        }
        XCTAssertTrue(plan.message.contains("every window, pane and process"),
                      "what stopping means is spelled out: \(plan.message)")
    }

    func testAnAgentFromAnotherTeamInTheSameSessionIsDisclosed() throws {
        // Stopping a session stops everything in it, including agents that are
        // not part of what is being deleted. They are named.
        let plan = SessionTerminationPlan(
            subject: .team(bench.topology),
            sessions: [SessionTerminationPlan.Session(
                id: "$1", name: "lead", server: Fixture.identity,
                agents: ["Lead"], otherTeams: ["Guest (Other)"])])

        XCTAssertTrue(plan.sessions[0].isSharedElsewhere)
        XCTAssertTrue(plan.message.contains("Guest (Other)"), plan.message)
        XCTAssertTrue(plan.message.contains("other teams"), plan.message)
        XCTAssertTrue(plan.sessions[0].summary.contains("also used by"))
    }

    func testStoppingOneSessionAsksAboutThatSessionOnly() async throws {
        try await bench.bindEverything()
        let session = try XCTUnwrap(bench.model.readout.sessions.first)
        let server = try XCTUnwrap(bench.model.readout.server)

        env.requestTermination(of: session, on: server)

        let plan = try XCTUnwrap(env.pendingTermination)
        XCTAssertEqual(plan.sessions.map(\.id), [session.id])
        XCTAssertNil(plan.topology, "no team is being removed")
        XCTAssertTrue(plan.title.contains(session.name), plan.title)
    }

    func testASessionRowFromAnOlderServerIsNotActedOn() async throws {
        // The row was drawn before tmux restarted; clicking it now must not
        // point at whatever has that id on the new server.
        try await bench.bindEverything()
        let session = try XCTUnwrap(bench.model.readout.sessions.first)
        let stale = TmuxServerIdentity(pid: 1, socketPath: "/tmp/old", startTime: 1)

        env.requestTermination(of: session, on: stale)

        XCTAssertNil(env.pendingTermination, "there is nothing to ask about")
    }

    func testCancellingChangesNothing() async throws {
        try await bench.bindEverything()
        env.requestDeletion(of: bench.topology)

        env.cancelDeletion()

        XCTAssertNil(env.pendingTermination)
        XCTAssertNotNil(bench.model.workspace.topology(bench.topology.id), "the team is still here")
        XCTAssertTrue(bench.runner.calls(of: "if-shell").isEmpty)
    }

    // MARK: - Doing it

    func testKeepingSessionsRemovesTheTeamAndStopsNothing() async throws {
        try await bench.bindEverything()
        env.requestDeletion(of: bench.topology)
        let plan = try XCTUnwrap(env.pendingTermination)

        await env.confirmDeletion(plan, terminating: false)

        XCTAssertNil(bench.model.workspace.topology(bench.topology.id))
        XCTAssertTrue(bench.runner.calls(of: "if-shell").isEmpty, "nothing was stopped")
    }

    func testStoppingSessionsAsksTmuxByIdNotByName() async throws {
        try await bench.bindEverything()
        env.requestDeletion(of: bench.topology)
        let plan = try XCTUnwrap(env.pendingTermination)

        await env.confirmDeletion(plan, terminating: true)

        // The check and the kill are one command, named by tmux's own id.
        let kills = bench.runner.calls(of: "if-shell")
        XCTAssertEqual(kills.count, plan.sessions.count)
        for call in kills {
            let killArgument = try XCTUnwrap(call.arguments.first { $0.hasPrefix("kill-session") })
            XCTAssertTrue(killArgument.contains(" -t $"),
                          "by id, which is never reused: \(killArgument)")
            XCTAssertTrue(call.arguments.contains { $0.contains("#{==:#{pid}") },
                          "and only on the server it belongs to")
        }
    }

    func testASessionThatCannotBeStoppedKeepsTheTeamAndSaysSo() async throws {
        try await bench.bindEverything()
        env.requestDeletion(of: bench.topology)
        let plan = try XCTUnwrap(env.pendingTermination)
        // tmux still lists them afterwards: the kill did not take.
        bench.runner.stub("if-shell", CommandResult(exitCode: 1, standardError: "no server"))

        await env.confirmDeletion(plan, terminating: true)

        XCTAssertNotNil(bench.model.workspace.topology(bench.topology.id),
                        "half of what was asked for is not what was asked for")
        XCTAssertEqual(bench.model.banner?.kind, .failure)
        XCTAssertTrue(bench.model.banner?.detail?.contains("try again") ?? false,
                      "\(String(describing: bench.model.banner?.detail))")
    }

    func testATeamWhoseRemovalFailsKeepsItsBanner() async throws {
        try await bench.bindEverything()
        env.requestDeletion(of: bench.topology)
        let plan = try XCTUnwrap(env.pendingTermination)

        // The kills work: each one takes its own session out of what tmux
        // lists, so the team removal is really reached.
        let runner = bench.runner
        let remaining = SessionList(sessions: bench.model.readout.sessions.map(\.id))
        runner.beforeCall = { invocation in
            guard runner.subcommand(of: invocation.arguments) == "if-shell",
                  let killed = invocation.arguments
                      .first(where: { $0.hasPrefix("kill-session") })?
                      .split(separator: " ").last
            else { return }
            remaining.remove(String(killed))
            runner.stub("list-sessions", CommandResult(
                exitCode: 0,
                standardOutput: Fixture.output(remaining.ids.map { [$0, $0, "1700", "0", "1"] })))
        }
        // And then the workspace cannot be written.
        let workspace = bench.root.appendingPathComponent("workspace")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: workspace.path)
        defer {
            runner.beforeCall = nil
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: workspace.path)
        }

        await env.confirmDeletion(plan, terminating: true)

        XCTAssertEqual(bench.runner.calls(of: "if-shell").count, plan.sessions.count,
                       "the sessions really were stopped")
        XCTAssertTrue(bench.model.readout.sessions.isEmpty, "and tmux agrees they are gone")
        XCTAssertNotNil(bench.model.workspace.topology(bench.topology.id),
                        "the team is still here, because saving that it was gone failed")
        XCTAssertEqual(bench.model.banner?.kind, .failure)
        XCTAssertFalse(bench.model.banner?.title.contains("stopped") ?? false,
                       "the failure is what is on screen: "
                           + "\(String(describing: bench.model.banner?.title))")
    }

    func testASessionWhosePaneIsGoneIsStillOffered() async throws {
        // The agent's pane was closed but its session is still running: this is
        // exactly the leftover the user complained about.
        try await bench.bindEverything()
        bench.runner.stub("list-panes", CommandResult(exitCode: 0))
        await bench.model.refresh()

        env.requestDeletion(of: bench.topology)

        let plan = try XCTUnwrap(env.pendingTermination)
        XCTAssertFalse(plan.sessions.isEmpty,
                       "a bound session that is still running is still something to stop")
    }

    func testASessionThatHasAlreadyEndedIsNotAFailure() async throws {
        try await bench.bindEverything()
        let plan = SessionTerminationPlan(
            subject: .session,
            sessions: [SessionTerminationPlan.Session(
                id: "$404", name: "gone", server: try XCTUnwrap(bench.model.readout.server))])

        await env.confirmTermination(plan)

        XCTAssertTrue(bench.runner.calls(of: "if-shell").isEmpty, "there was nothing to kill")
        XCTAssertEqual(bench.model.banner?.kind, .success)
        XCTAssertTrue(bench.model.banner?.detail?.contains("already ended") ?? false,
                      "\(String(describing: bench.model.banner?.detail))")
    }
}
