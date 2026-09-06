import XCTest
import MarmyCore
@testable import MarmyRuntime

final class LaunchPreflightTests: XCTestCase {

    private var environment: TestEnvironment!

    override func setUpWithError() throws {
        environment = try TestEnvironment()
    }

    override func tearDownWithError() throws {
        environment.cleanUp()
    }

    private func evaluate(
        topology: Topology? = nil,
        workspace: Workspace? = nil,
        sessions: [TmuxSession] = [],
        states: [UUID: AgentRuntimeState] = [:],
        bindings: [UUID: AgentBinding] = [:],
        locator: ExecutableLocator? = nil,
        trampoline: TrampolineCommand? = nil
    ) -> PreflightReport {
        let directory = environment.workingDirectory.path
        return LaunchPreflight.evaluate(
            topology: topology ?? Team.topology(workingDirectory: directory),
            workspace: workspace ?? Team.workspace(workingDirectory: directory),
            liveSessions: sessions,
            states: states,
            bindings: bindings,
            locator: locator ?? environment.locator,
            trampoline: trampoline ?? environment.trampoline)
    }

    private func session(_ id: String, _ name: String) -> TmuxSession {
        TmuxSession(id: id, name: name, created: 1700, isAttached: false, windowCount: 1)
    }

    func testAHealthyTeamPlansEveryNode() {
        let report = evaluate()
        XCTAssertFalse(report.isBlocked)
        XCTAssertEqual(report.plans.map(\.sessionName), ["lead", "build"])
        XCTAssertTrue(report.plans.allSatisfy { $0.executablePath.hasSuffix("/claude") })
        XCTAssertTrue(report.plans.allSatisfy { $0.arguments.contains("--") })
    }

    func testGraphErrorsBlockTheWholeLaunch() {
        var topology = Team.topology(workingDirectory: environment.workingDirectory.path)
        topology.nodes[1].parentID = UUID()  // manager is not in the team
        let report = evaluate(topology: topology)

        XCTAssertTrue(report.isBlocked)
        XCTAssertTrue(report.errors.contains { if case .topologyInvalid = $0.kind { return true } else { return false } })
    }

    func testMissingWorkingDirectoryIsAnError() {
        var topology = Team.topology(workingDirectory: environment.workingDirectory.path)
        topology.nodes[1].workingDirectory = "/definitely/not/here"
        let report = evaluate(topology: topology)

        XCTAssertTrue(report.isBlocked)
        XCTAssertTrue(report.errors.contains {
            $0.kind == .workingDirectoryMissing(path: "/definitely/not/here")
        })
        XCTAssertFalse(report.plans.contains { $0.nodeID == Team.workerID })
    }

    func testAFileWhereAFolderIsExpectedIsAnError() throws {
        let file = environment.workingDirectory.appendingPathComponent("notafolder")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        var topology = Team.topology(workingDirectory: environment.workingDirectory.path)
        topology.nodes[0].workingDirectory = file.path

        XCTAssertTrue(evaluate(topology: topology).errors.contains {
            $0.kind == .workingDirectoryNotADirectory(path: file.path)
        })
    }

    func testMissingCLINamesTheToolAndBlocks() {
        let report = evaluate(locator: ExecutableLocator(searchDirectories: ["/nonexistent"]))
        XCTAssertTrue(report.isBlocked)
        XCTAssertTrue(report.errors.contains { $0.kind == .cliMissing(name: "claude") })
        XCTAssertTrue(report.errors.first { $0.kind == .cliMissing(name: "claude") }!
            .message.contains("claude"))
    }

    func testASessionNameAlreadyInUseBlocksThatNode() {
        // Taking over someone's session is never the answer.
        let report = evaluate(sessions: [session("$9", "build")])

        XCTAssertTrue(report.isBlocked)
        XCTAssertTrue(report.errors.contains { $0.kind == .sessionNameInUse(name: "build", sessionID: "$9") })
        XCTAssertFalse(report.plans.contains { $0.sessionName == "build" })
    }

    func testARunningNodeIsSkippedNotRestarted() {
        let report = evaluate(
            sessions: [session("$1", "lead")],
            states: [Team.managerID: .running(paneID: "%1", sessionName: "lead", adopted: false)])

        XCTAssertFalse(report.isBlocked)
        XCTAssertEqual(report.alreadyRunning[Team.managerID], "lead")
        XCTAssertEqual(report.plans.map(\.sessionName), ["build"], "only the absent node is planned")
    }

    func testAMissingBindingWarnsAndPlansAFreshStart() {
        let report = evaluate(states: [Team.workerID: .missing(reason: "Session \u{22}build\u{22} has ended.")])
        XCTAssertFalse(report.isBlocked)
        XCTAssertTrue(report.warnings.contains { if case .bindingLost = $0.kind { return true } else { return false } })
        XCTAssertTrue(report.plans.contains { $0.nodeID == Team.workerID })
    }

    func testABrokenPromptTemplateBlocksTheNode() {
        var workspace = Team.workspace(workingDirectory: environment.workingDirectory.path)
        var broken = workspace.promptTemplate(DefaultTemplates.ID.workerPrompt)!
        broken.body = "Hello {{agent.nmae}}"
        workspace.upsert(broken)

        let report = evaluate(workspace: workspace)
        XCTAssertTrue(report.isBlocked)
    }

    func testAMissingTrampolineBlocksEverything() {
        let report = evaluate(trampoline: TrampolineCommand(executablePath: "/nonexistent/marmy-agent-launch"))
        XCTAssertTrue(report.isBlocked)
        XCTAssertTrue(report.errors.contains {
            $0.kind == .trampolineMissing(path: "/nonexistent/marmy-agent-launch")
        })
    }

    func testRequestingASubsetOnlyPlansThatSubset() {
        let directory = environment.workingDirectory.path
        let report = LaunchPreflight.evaluate(
            topology: Team.topology(workingDirectory: directory),
            workspace: Team.workspace(workingDirectory: directory),
            requestedNodeIDs: [Team.workerID],
            liveSessions: [],
            states: [:],
            bindings: [:],
            locator: environment.locator,
            trampoline: environment.trampoline)

        XCTAssertEqual(report.plans.map(\.sessionName), ["build"])
    }

    func testPlannedPromptsAddressRunningPeersByTheirLiveName() {
        // The manager was adopted into a session with a different name, so the
        // worker must be told where its manager actually is.
        let report = evaluate(
            sessions: [session("$4", "marmy_worker_opus")],
            states: [Team.managerID: .running(paneID: "%4", sessionName: "marmy_worker_opus", adopted: true)])

        let workerPlan = report.plans.first { $0.nodeID == Team.workerID }!
        XCTAssertTrue(workerPlan.initialPrompt.contains("marmy_worker_opus"))
        XCTAssertFalse(workerPlan.initialPrompt.contains("tmux session lead"))
    }

    func testStaleAttachmentsDoNotLeakIntoAFreshTeamsPrompts() {
        var topology = Team.topology(workingDirectory: environment.workingDirectory.path)
        topology.nodes[0].attachedSessionName = "session_from_last_week"
        let report = evaluate(topology: topology)

        let workerPlan = report.plans.first { $0.nodeID == Team.workerID }!
        XCTAssertFalse(workerPlan.initialPrompt.contains("session_from_last_week"))
        XCTAssertTrue(workerPlan.initialPrompt.contains("tmux session lead"))
    }

    func testResolvedNamesPreferLiveSessionsOverPlannedOnes() {
        let topology = Team.topology(workingDirectory: environment.workingDirectory.path)
        let names = LaunchPreflight.resolvedSessionNames(topology: topology, states: [
            Team.managerID: .running(paneID: "%1", sessionName: "renamed_live", adopted: true),
            Team.workerID: .notLaunched,
        ])
        XCTAssertEqual(names[Team.managerID], "renamed_live")
        XCTAssertEqual(names[Team.workerID], "build")
    }
}
