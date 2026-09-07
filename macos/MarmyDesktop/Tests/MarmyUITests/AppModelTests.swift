import XCTest
import MarmyCore
import MarmyRuntime
@testable import MarmyUI

/// Selection, drafts, editing rules, and what gets written to disk.
@MainActor
final class AppModelTests: XCTestCase {

    private var bench: TestBench!

    override func setUpWithError() throws {
        bench = try TestBench()
    }

    override func tearDown() {
        bench.cleanUp()
    }

    // MARK: - Drafts and sending

    // MARK: - Navigation

    func testNavigationMovesWithinTheTeamAndRemembersWhereItWas() {
        let model = bench.model
        model.select(node: bench.workers[1].id)
        model.move(.parent)
        XCTAssertEqual(model.selectedNodeID, bench.manager.id)

        model.move(.child)
        XCTAssertEqual(model.selectedNodeID, bench.workers[1].id, "it goes back to the report you were in")

        model.move(.nextPeer)
        XCTAssertEqual(model.selectedNodeID, bench.workers[0].id, "peers wrap around")
    }

    func testSelectionChangesAreAnnouncedOnce() {
        var changes = 0
        bench.model.onSelectionChanged = { changes += 1 }

        bench.model.select(node: bench.workers[0].id)
        bench.model.select(node: bench.workers[0].id)
        bench.model.move(.nextPeer)
        bench.model.mode = .topology

        XCTAssertEqual(changes, 3, "re-selecting the same agent is not a change")
    }

    func testCyclingAtTheRootLayerCrossesTeams() throws {
        let model = bench.model
        // A second team, so there are two orchestrators to move between.
        let other = Topology(name: "Other team", nodes: [AgentNode(
            sessionName: "other-lead", displayName: "Other lead", kind: .manager,
            workingDirectory: bench.root.path)])
        model.addTeam(other)
        model.select(node: bench.manager.id)

        model.move(.nextPeer)
        XCTAssertEqual(model.selectedNodeID, other.nodes[0].id, "root managers of every team are peers")
        XCTAssertEqual(model.selectedTopologyID, other.id, "the selected team follows")

        model.move(.nextPeer)
        XCTAssertEqual(model.selectedNodeID, bench.manager.id, "and it wraps")
    }

    func testReportsStayInsideTheirOwnTeamWhenCycling() {
        let model = bench.model
        let other = Topology(name: "Other team", nodes: [AgentNode(
            sessionName: "other-lead", displayName: "Other lead", kind: .manager,
            workingDirectory: bench.root.path)])
        model.addTeam(other)

        model.select(node: bench.workers[0].id)
        model.move(.nextPeer)
        XCTAssertEqual(model.selectedNodeID, bench.workers[1].id)
        model.move(.nextPeer)
        XCTAssertEqual(model.selectedNodeID, bench.workers[0].id, "workers cycle among their siblings only")
        XCTAssertEqual(model.selectedTopologyID, bench.topology.id)
    }

    func testEachTeamRemembersWhereYouWere() {
        let model = bench.model
        let otherManagerID = UUID()
        let other = Topology(name: "Other team", nodes: [
            AgentNode(
                id: otherManagerID, sessionName: "other-lead", displayName: "Other lead",
                kind: .manager, workingDirectory: bench.root.path),
            AgentNode(
                sessionName: "other-worker", displayName: "Other worker", kind: .worker,
                workingDirectory: bench.root.path, parentID: otherManagerID),
        ])
        model.addTeam(other)

        // Go into a report in the first team, then across to the other team.
        model.select(node: bench.workers[1].id)
        model.move(.parent)
        model.move(.nextPeer)
        XCTAssertEqual(model.selectedTopologyID, other.id)

        // Coming back lands on the manager, and down returns to that report.
        model.move(.previousPeer)
        XCTAssertEqual(model.selectedNodeID, bench.manager.id)
        model.move(.child)
        XCTAssertEqual(model.selectedNodeID, bench.workers[1].id)
    }

    // MARK: - Sidebar

    func testTeamsCanAllBeCollapsedAndSelectionDoesNotReopenThem() {
        let model = bench.model
        XCTAssertTrue(model.isExpanded(bench.topology.id), "the first team starts open")

        model.toggleExpansion(bench.topology.id)
        XCTAssertFalse(model.isExpanded(bench.topology.id))

        model.select(node: bench.workers[0].id)
        XCTAssertFalse(model.isExpanded(bench.topology.id), "selecting an agent does not force a team open")

        model.toggleExpansion(bench.topology.id)
        XCTAssertTrue(model.isExpanded(bench.topology.id))
    }

    // MARK: - Naming

    func testNewAgentsGetDistinctReadableNames() throws {
        let model = bench.model
        let first = try XCTUnwrap(model.addNode(kind: .worker, parentID: bench.manager.id))
        let second = try XCTUnwrap(model.addNode(kind: .worker, parentID: bench.manager.id))
        let manager = try XCTUnwrap(model.addNode(kind: .manager, parentID: nil))

        XCTAssertEqual(first.displayName, "Worker 1")
        XCTAssertEqual(second.displayName, "Worker 2")
        XCTAssertEqual(manager.displayName, "Manager 1")
        XCTAssertEqual(Set([first.sessionName, second.sessionName, manager.sessionName]).count, 3)
        XCTAssertEqual(first.sessionName, "worker-1")
    }

    func testNewAgentNamesAvoidWhatIsAlreadyRunning() throws {
        let model = bench.model
        var topology = try XCTUnwrap(model.selectedTopology)
        topology.nodes[1].displayName = "Worker 1"
        model.update(topology)

        let added = try XCTUnwrap(model.addNode(kind: .worker, parentID: bench.manager.id))
        XCTAssertEqual(added.displayName, "Worker 2")
    }

    // MARK: - Deleting a team

    func testDeletingATeamRepairsTheSelectionAndLeavesSessionsAlone() async throws {
        try await bench.bindEverything()
        let model = bench.model
        let other = Topology(name: "Other team", nodes: [AgentNode(
            sessionName: "other-lead", displayName: "Other lead", kind: .manager,
            workingDirectory: bench.root.path)])
        model.addTeam(other)
        model.selectTopology(bench.topology.id)

        bench.env.requestDeletion(of: bench.topology)
        let plan = try XCTUnwrap(bench.env.pendingTermination, "deleting asks first")
        await bench.env.confirmDeletion(plan, terminating: false)

        XCTAssertEqual(model.topologies.map(\.id), [other.id])
        XCTAssertEqual(model.selectedTopologyID, other.id, "the selection moves to what is left")
        XCTAssertTrue(bench.runner.calls(of: "kill-session").isEmpty, "sessions keep running")
    }

    func testDeletingATeamEndsDictationFirst() async throws {
        let model = bench.model
        model.select(node: bench.workers[0].id)
        bench.env.voice.beginHold(on: .node(bench.workers[0].id))
        XCTAssertTrue(bench.env.voice.isCapturing)

        bench.env.requestDeletion(of: bench.topology)
        XCTAssertFalse(bench.env.voice.isCapturing, "asking the question already stops recording")
        let plan = try XCTUnwrap(bench.env.pendingTermination)
        await bench.env.confirmDeletion(plan, terminating: false)

        XCTAssertFalse(bench.env.voice.isCapturing)
        XCTAssertNil(bench.env.voice.target)
    }

    func testTheDialogClosingBeforeTheActionRunsStillDeletesTheRightTeam() async throws {
        let model = bench.model
        let other = Topology(name: "Other team", nodes: [AgentNode(
            sessionName: "other-lead", displayName: "Other lead", kind: .manager,
            workingDirectory: bench.root.path)])
        model.addTeam(other)
        model.selectTopology(bench.topology.id)

        bench.env.requestDeletion(of: bench.topology)
        let plan = try XCTUnwrap(bench.env.pendingTermination)
        // SwiftUI clears the presentation binding before the action's task runs.
        bench.env.teamPendingDeletion = nil
        bench.env.pendingTermination = nil
        await bench.env.confirmDeletion(plan, terminating: false)

        XCTAssertEqual(model.topologies.map(\.id), [other.id])
    }

    func testCancellingDeletesNothing() async throws {
        let model = bench.model
        bench.env.requestDeletion(of: bench.topology)
        bench.env.cancelDeletion()

        XCTAssertNil(bench.env.teamPendingDeletion)
        XCTAssertEqual(model.topologies.count, 1)
        XCTAssertEqual(model.selectedTopologyID, bench.topology.id)
    }

    func testDeletingAnotherTeamLeavesYourSelectionAlone() async throws {
        let model = bench.model
        let other = Topology(name: "Other team", nodes: [AgentNode(
            sessionName: "other-lead", displayName: "Other lead", kind: .manager,
            workingDirectory: bench.root.path)])
        model.addTeam(other)

        model.select(node: bench.workers[1].id)

        await bench.env.confirmDeletion(
            SessionTerminationPlan(subject: .team(other), sessions: []), terminating: false)

        XCTAssertEqual(model.selectedTopologyID, bench.topology.id)
        XCTAssertEqual(model.selectedNodeID, bench.workers[1].id, "the agent you were on is untouched")
        XCTAssertEqual(model.topologies.map(\.id), [bench.topology.id])
    }

    func testDeletingTheSelectedTeamLandsOnARealAgent() async throws {
        let model = bench.model
        let otherManagerID = UUID()
        let other = Topology(name: "Other team", nodes: [
            AgentNode(
                id: otherManagerID, sessionName: "other-lead", displayName: "Other lead",
                kind: .manager, workingDirectory: bench.root.path),
            AgentNode(
                sessionName: "other-worker", displayName: "Other worker", kind: .worker,
                workingDirectory: bench.root.path, parentID: otherManagerID),
        ])
        model.addTeam(other)
        model.selectTopology(bench.topology.id)
        model.inspectedNodeID = bench.workers[0].id
        // Everything closed: deleting must not reopen anything.
        model.expandedTopologyIDs = []

        await bench.env.confirmDeletion(
            SessionTerminationPlan(subject: .team(bench.topology), sessions: []),
            terminating: false)

        XCTAssertEqual(model.selectedTopologyID, other.id)
        XCTAssertEqual(model.selectedNodeID, otherManagerID, "the header shows a real agent")
        XCTAssertNil(model.inspectedNodeID, "the inspector lets go of the deleted agent")
        XCTAssertFalse(model.isExpanded(other.id), "a collapsed sidebar stays collapsed")
        XCTAssertFalse(model.isExpanded(bench.topology.id))
    }

    func testAFailedSaveLeavesTheTeamAndItsBindingsAlone() async throws {
        try await bench.bindEverything()
        let model = bench.model
        let workspaceDirectory = bench.root.appendingPathComponent("workspace")
        // Make the write fail without touching what is already on disk.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: workspaceDirectory.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: workspaceDirectory.path)
        }

        await bench.env.confirmDeletion(
            SessionTerminationPlan(subject: .team(bench.topology), sessions: []),
            terminating: false)

        XCTAssertEqual(model.topologies.count, 1, "the team is still here")
        XCTAssertEqual(model.selectedTopologyID, bench.topology.id)
        XCTAssertEqual(model.banner?.kind, .failure)
        let binding = await model.runtime.binding(for: bench.manager.id)
        XCTAssertNotNil(binding, "its bindings were not thrown away for a save that never happened")
    }

    // MARK: - Editing rules

    func testAManagerWithReportsMayBecomeAWorkerAndKeepThem() {
        // What an agent does and who reports to it are separate questions.
        let model = bench.model
        let reportsBefore = model.selectedTopology?.children(of: bench.manager.id).map(\.id)

        model.changeKind(of: bench.manager.id, to: .worker)

        XCTAssertEqual(model.selectedTopology?.node(bench.manager.id)?.kind, .worker)
        XCTAssertEqual(model.selectedTopology?.children(of: bench.manager.id).map(\.id), reportsBefore,
                       "its reports stay exactly where they are")
        XCTAssertNil(model.banner)
    }

    func testChangingKindKeepsAValidRolePrompt() {
        let model = bench.model
        let worker = bench.workers[0]
        model.changeKind(of: worker.id, to: .manager)

        let updated = model.selectedTopology?.node(worker.id)
        XCTAssertEqual(updated?.kind, .manager)
        let template = updated?.promptTemplateID.flatMap { model.workspace.promptTemplate($0) }
        XCTAssertEqual(template?.applicability.matches(.manager), true)
    }

    func testANewAgentDoesNotReferenceADeletedTemplate() {
        let model = bench.model
        model.deletePromptTemplate(DefaultTemplates.ID.workerPrompt)

        let node = model.addNode(kind: .worker, parentID: bench.manager.id)
        XCTAssertNotEqual(node?.promptTemplateID, DefaultTemplates.ID.workerPrompt)
        if let templateID = node?.promptTemplateID {
            XCTAssertNotNil(model.workspace.promptTemplate(templateID))
        }
    }

    func testReparentingRefusesLoopsWithAnExplanation() {
        let model = bench.model
        // Both workers become managers, then one reports to the other.
        model.changeKind(of: bench.workers[0].id, to: .manager)
        model.changeKind(of: bench.workers[1].id, to: .manager)
        XCTAssertTrue(model.reparent(bench.workers[1].id, to: bench.workers[0].id))

        // Closing the loop the other way has to be refused, in plain words.
        XCTAssertFalse(model.reparent(bench.workers[0].id, to: bench.workers[1].id))
        XCTAssertEqual(model.banner?.kind, .failure)
        XCTAssertTrue(model.banner?.detail?.contains("one way") ?? false,
                      "\(String(describing: model.banner?.detail))")
    }

    func testAWorkerMayBeGivenReports() {
        let model = bench.model
        let leader = bench.workers[0]
        let follower = bench.workers[1]

        XCTAssertTrue(model.reparent(follower.id, to: leader.id))

        XCTAssertEqual(model.selectedTopology?.node(follower.id)?.parentID, leader.id)
        XCTAssertEqual(model.selectedTopology?.node(leader.id)?.kind, .worker, "still a worker")
        XCTAssertNil(model.banner)
    }

    func testAddingAnAgentPutsItUnderWhicheverAgentWasAskedFor() {
        let model = bench.model
        let worker = bench.workers[0]

        let added = model.addNode(kind: .worker, parentID: worker.id)

        XCTAssertEqual(added?.parentID, worker.id, "not quietly moved up to a manager")
    }

    // MARK: - Persistence

    func testGraphEditsAndPositionsSurviveAReopen() throws {
        let model = bench.model
        var topology = try XCTUnwrap(model.selectedTopology)
        topology.setPosition(.init(x: 120, y: 340), for: bench.workers[0].id)
        topology.nodes[0].roleTitle = "Reviews everything"
        model.update(topology)

        let store = WorkspaceStore(directoryURL: bench.root.appendingPathComponent("workspace"))
        let reopened = try store.load()
        let reloaded = try XCTUnwrap(reopened.topology(topology.id))

        XCTAssertEqual(reloaded.position(of: bench.workers[0].id)?.x, 120)
        XCTAssertEqual(reloaded.nodes[0].roleTitle, "Reviews everything")
    }

    func testSavingATeamShapeAndStampingOutAFreshOne() throws {
        let model = bench.model
        model.saveSelectedTeamAsTemplate(named: "My shape")
        let template = try XCTUnwrap(model.workspace.topologyTemplates.first { $0.name == "My shape" })

        let created = try XCTUnwrap(model.instantiate(templateID: template.id, named: "Second team", directory: nil))
        XCTAssertEqual(model.topologies.count, 2)
        XCTAssertTrue(Set(created.nodes.map(\.id)).isDisjoint(with: Set(bench.topology.nodes.map(\.id))))
        XCTAssertTrue(Set(created.nodes.map(\.sessionName))
            .isDisjoint(with: Set(bench.topology.nodes.map(\.sessionName))),
            "a new team never reuses running session names")
    }

    func testAWorkspaceThatWillNotLoadIsNeverOverwritten() throws {
        let directory = bench.root.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = WorkspaceStore(directoryURL: directory)
        let garbage = "{ not json"
        try garbage.write(to: store.fileURL, atomically: true, encoding: .utf8)

        let runtime = try AgentRuntime(
            tmux: TmuxClient(executablePath: "/usr/bin/true", runner: bench.runner),
            store: RuntimeStore(directoryURL: directory.appendingPathComponent("runtime")))
        let model = AppModel(store: store, runtime: runtime)

        XCTAssertNotNil(model.loadFailure)
        XCTAssertFalse(model.save(), "saving over an unreadable file is refused")
        XCTAssertEqual(try String(contentsOf: store.fileURL, encoding: .utf8), garbage)
    }

    // MARK: - Runtime state

    func testRemovingATeamKeepsItsSessionsRunning() async throws {
        try await bench.bindEverything()
        let sessionsBefore = bench.runner.calls(of: "kill-session").count

        await bench.model.deleteSelectedTopology()

        XCTAssertEqual(bench.runner.calls(of: "kill-session").count, sessionsBefore,
                       "removing a team never kills anything")
        XCTAssertTrue(bench.model.topologies.isEmpty)
    }

    func testALocalSessionIsIdentifiedByItsServerToo() {
        let first = LocalSessionKey(sessionID: "$0", server: Fixture.identity, paneID: "%0")
        let afterRestart = LocalSessionKey(
            sessionID: "$0",
            server: TmuxServerIdentity(pid: 999, socketPath: "/tmp/tmux-501/default", startTime: 1999),
            paneID: "%0")

        XCTAssertNotEqual(first, afterRestart)
        XCTAssertNotEqual(WorkTarget.localSession(first).id, WorkTarget.localSession(afterRestart).id,
                          "a reused session id cannot inherit an old draft")
        XCTAssertFalse(afterRestart.matches(Fixture.identity))
    }

    func testStartupFailureBlocksEverythingThatWouldTouchAnAgent() async throws {
        let directory = bench.root.appendingPathComponent("blocked", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let runtime = try AgentRuntime(
            tmux: TmuxClient(executablePath: "/usr/bin/true", runner: bench.runner),
            store: RuntimeStore(directoryURL: directory))
        let model = AppModel(
            store: WorkspaceStore(directoryURL: directory),
            runtime: runtime,
            startupFailure: "tmux was not found.")

        await model.launchSelectedTeam()
        XCTAssertEqual(model.banner?.kind, .failure)
        XCTAssertTrue(bench.runner.calls(of: "new-session").isEmpty)
    }
}

/// Editing one team while looking at another.
///
/// The sidebar shows every team at once, so a right-click can land on an agent
/// in a team that is not selected. What happens next has to happen there.
@MainActor
final class CrossTeamEditingTests: XCTestCase {

    private var bench: TestBench!
    private var other: Topology!

    override func setUpWithError() throws {
        bench = try TestBench()
        // A second team, not the selected one.
        var team = Topology(name: "Other team", nodes: [])
        let lead = AgentNode(
            sessionName: "other-lead", displayName: "Other Lead", kind: .manager,
            workingDirectory: bench.root.path)
        team.upsert(lead)
        bench.model.addTeam(team)
        other = team
        bench.model.selectTopology(bench.topology.id)
    }

    override func tearDownWithError() throws {
        bench.cleanUp()
    }

    private var otherLead: AgentNode { other.roots[0] }

    func testAddingUnderAnAgentOfAnotherTeamAddsItThere() throws {
        let model = bench.model
        XCTAssertEqual(model.selectedTopologyID, bench.topology.id)

        let added = try XCTUnwrap(model.addNode(kind: .worker, parentID: otherLead.id))

        let owner = try XCTUnwrap(model.workspace.topologies.first { $0.contains(added.id) })
        XCTAssertEqual(owner.id, other.id, "it belongs beside the agent it was added under")
        XCTAssertEqual(added.parentID, otherLead.id, "and its parent was not silently dropped")
        XCTAssertNil(bench.topology.node(added.id), "nothing was added to the team on screen")
    }

    func testAddingUnderAnAgentThatIsNotThereAddsNothing() {
        let model = bench.model
        let before = model.workspace.topologies.map(\.nodes.count)

        XCTAssertNil(model.addNode(kind: .worker, parentID: UUID()),
                     "a parent that cannot be found is a mistake, not a root somewhere else")

        XCTAssertEqual(model.workspace.topologies.map(\.nodes.count), before)
        XCTAssertEqual(model.selectedTopologyID, bench.topology.id, "and nothing was selected")
    }

    func testDeletingAnAgentOfAnotherTeamDeletesItThere() async throws {
        let model = bench.model
        let doomed = try XCTUnwrap(model.addNode(kind: .worker, parentID: otherLead.id))
        model.selectTopology(bench.topology.id)

        var changed: [UUID] = []
        model.onTopologyChanged = { changed.append($0) }
        await model.deleteNode(doomed.id)

        XCTAssertNil(
            model.workspace.topologies.first { $0.contains(doomed.id) },
            "it is gone from the team it was in")
        XCTAssertEqual(model.workspace.topology(bench.topology.id)?.nodes.count,
                       bench.topology.nodes.count, "and the selected team is untouched")
        XCTAssertTrue(changed.contains(other.id),
                      "the agents left behind are owed the team without it")
    }

    func testDeletingKeepsTheReportsOfTheAgentItRemoves() async throws {
        let model = bench.model
        let middle = try XCTUnwrap(model.addNode(kind: .worker, parentID: otherLead.id))
        let under = try XCTUnwrap(model.addNode(kind: .worker, parentID: middle.id))
        model.selectTopology(bench.topology.id)

        await model.deleteNode(middle.id)

        let owner = try XCTUnwrap(model.workspace.topologies.first { $0.contains(under.id) })
        XCTAssertEqual(owner.node(under.id)?.parentID, otherLead.id,
                       "its report moved up rather than being deleted with it")
    }
}
