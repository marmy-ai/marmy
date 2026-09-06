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

    func testADraftBelongsToTheAgentItWasWrittenFor() {
        let model = bench.model
        let first = WorkTarget.node(bench.workers[0].id)
        let second = WorkTarget.node(bench.workers[1].id)

        model.drafts.setText("for the implementer", for: first)
        model.drafts.setText("for the verifier", for: second)

        XCTAssertEqual(model.drafts.text(for: first), "for the implementer")
        XCTAssertEqual(model.drafts.text(for: second), "for the verifier")
    }

    func testTextTypedWhileAMessageIsInFlightIsNotThrownAway() async throws {
        try await bench.bindEverything()
        let target = WorkTarget.node(bench.workers[0].id)
        bench.model.drafts.setText("first message", for: target)
        // The send takes a moment, which is when the user types the next thing.
        bench.runner.delay = 0.15

        let send = Task { await bench.model.sendDraft(from: target, clientPID: 41) }
        try await Task.sleep(for: .milliseconds(60))
        bench.model.drafts.setText("first message, and more", for: target)
        _ = await send.value

        XCTAssertEqual(bench.model.drafts.text(for: target), "first message, and more",
                       "only the exact text that was sent may be cleared")
    }

    func testADeliveredDraftIsCleared() async throws {
        try await bench.bindEverything()
        let target = WorkTarget.node(bench.workers[0].id)
        bench.model.drafts.setText("ship it", for: target)

        await bench.model.sendDraft(from: target, clientPID: 41)
        XCTAssertTrue(bench.model.drafts.isEmpty(target))
    }

    func testAFailedSendKeepsTheDraft() async throws {
        try await bench.bindEverything()
        let target = WorkTarget.node(bench.workers[0].id)
        bench.model.drafts.setText("do not lose me", for: target)
        bench.runner.stub("paste-buffer", CommandResult(exitCode: 1, standardError: "can't find pane: %1"))

        let delivered = await bench.model.sendDraft(from: target, clientPID: 41)
        XCTAssertFalse(delivered)
        XCTAssertEqual(bench.model.drafts.text(for: target), "do not lose me")
        XCTAssertNotNil(bench.model.banner)
    }

    func testSendingNeedsAnAttachedTerminal() async throws {
        try await bench.bindEverything()
        let target = WorkTarget.node(bench.workers[0].id)
        bench.model.drafts.setText("hello", for: target)

        // No terminal has been attached for this target, so the environment
        // refuses rather than sending somewhere it cannot verify.
        await bench.env.sendDraft(from: target)

        XCTAssertEqual(bench.model.drafts.text(for: target), "hello")
        XCTAssertTrue(bench.runner.calls(of: "load-buffer").isEmpty)
        XCTAssertEqual(bench.model.banner?.kind, .failure)
    }

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

    // MARK: - Editing rules

    func testAManagerWithReportsCannotQuietlyBecomeAWorker() {
        let model = bench.model
        model.changeKind(of: bench.manager.id, to: .worker)

        XCTAssertEqual(model.selectedTopology?.node(bench.manager.id)?.kind, .manager)
        XCTAssertEqual(model.banner?.kind, .failure)
        XCTAssertTrue(model.banner?.detail?.contains("Build") ?? false, "it names the reports to move")
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

    func testAWorkerCannotBeGivenReports() {
        let model = bench.model
        XCTAssertFalse(model.reparent(bench.manager.id, to: bench.workers[0].id))
        XCTAssertTrue(model.banner?.detail?.contains("worker") ?? false,
                      "\(String(describing: model.banner?.detail))")
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
