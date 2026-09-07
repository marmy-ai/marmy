import XCTest
import MarmyCore
import MarmyRuntime
@testable import MarmyUI

/// Keeping every agent's picture of its own team up to date.
@MainActor
final class RosterCoordinatorTests: XCTestCase {

    private var bench: TestBench!
    private var roster: RosterCoordinator { bench.env.roster }

    override func setUpWithError() throws {
        bench = try TestBench()
    }

    override func tearDownWithError() throws {
        bench.cleanUp()
    }

    private func prepare() async throws {
        try await bench.bindEverything()
        // The first look at the server is what "now" means.
        await roster.observeState()
    }

    private func rosterEntries() async throws -> [JournalEntry] {
        try await bench.model.runtime.journal.all().filter { $0.kind == .rosterUpdate }
    }

    private var manager: AgentNode { bench.topology.roots[0] }
    private var workers: [AgentNode] { bench.topology.children(of: manager.id) }

    private func rename(_ node: AgentNode, to name: String) {
        var topology = bench.model.workspace.topology(bench.topology.id)!
        var updated = topology.node(node.id)!
        updated.displayName = name
        topology.upsert(updated)
        bench.model.update(topology)
    }

    // MARK: - When nothing has changed

    func testNothingIsSaidWhenMarmyStarts() async throws {
        try await prepare()
        await roster.reconcile()

        let entries = try await rosterEntries()
        XCTAssertTrue(entries.isEmpty, "agents were told their team in their own starting prompts")
        XCTAssertTrue(roster.pending.isEmpty)
    }

    func testARefreshThatFindsNothingNewSaysNothing() async throws {
        try await prepare()
        await roster.observeState()
        await roster.observeState()

        let entries = try await rosterEntries()
        XCTAssertTrue(entries.isEmpty)
    }

    func testAnEditThatCancelsItselfOutSaysNothing() async throws {
        try await prepare()

        var topology = bench.model.workspace.topology(bench.topology.id)!
        let extra = AgentNode(
            sessionName: "extra", displayName: "Extra", kind: .worker,
            workingDirectory: bench.root.path, parentID: manager.id)
        topology.upsert(extra)
        bench.model.update(topology)
        topology.remove(extra.id)
        bench.model.update(topology)

        await roster.reconcile()
        let entries = try await rosterEntries()
        XCTAssertTrue(entries.isEmpty, "the team is as it was, so there is nothing to say")
    }

    // MARK: - When something has

    func testAddingAReportTellsTheManager() async throws {
        try await prepare()

        var topology = bench.model.workspace.topology(bench.topology.id)!
        topology.upsert(AgentNode(
            sessionName: "extra", displayName: "Extra", kind: .worker, roleTitle: "Extra hands",
            workingDirectory: bench.root.path, parentID: manager.id))
        bench.model.update(topology)
        await roster.reconcile()

        let entries = try await rosterEntries()
        let toManager = try XCTUnwrap(entries.first { $0.nodeID == manager.id })
        XCTAssertTrue(toManager.payload.contains("Extra"))
        XCTAssertTrue(toManager.payload.contains("as it stands now"),
                      "the whole picture, not a running commentary")
        XCTAssertFalse(toManager.payload.contains("\n"))
    }

    func testTheNewestDescriptionReplacesOneThatNeverWent() async throws {
        try await prepare()
        rename(workers[0], to: "Renamed Once")
        await roster.reconcile()
        let first = try await rosterEntries()
        XCTAssertFalse(first.isEmpty, "the first update is waiting for a free prompt")

        rename(workers[0], to: "Renamed Twice")
        await roster.reconcile()

        let entries = try await rosterEntries()
        let superseded = entries.filter { $0.status == .superseded }
        XCTAssertEqual(superseded.count, first.count, "the older description stood down")
        XCTAssertTrue(entries.contains { $0.status == .prepared && $0.payload.contains("Renamed Twice") })
        XCTAssertEqual(
            roster.pendingItems(forNode: manager.id).count, 1,
            "one waiting update per agent, saying what is true now")
    }

    func testAnUncertainUpdateIsNotQuietlyReplaced() async throws {
        try await prepare()
        rename(workers[0], to: "Renamed")
        await roster.reconcile()
        let waiting = try XCTUnwrap(roster.pendingItems(forNode: manager.id).first)

        // Marmy could not tell whether that one arrived.
        _ = try await bench.model.runtime.journal.update(
            waiting.entry.id, status: .uncertain, detail: "stopped mid-send")

        rename(workers[0], to: "Renamed Again")
        await roster.reconcile()

        let stored = try await bench.model.runtime.journal.entry(id: waiting.entry.id)
        XCTAssertEqual(stored?.status, .uncertain,
                       "an attempt nobody can account for is history, not a draft")
    }

    func testAManualTerminalIsNeverToldAnything() async throws {
        try await prepare()
        var topology = bench.model.workspace.topology(bench.topology.id)!
        var worker = topology.node(workers[0].id)!
        worker.cli = .terminal
        topology.upsert(worker)
        bench.model.update(topology)

        await roster.reconcile()

        let entries = try await rosterEntries()
        XCTAssertFalse(entries.contains { $0.nodeID == worker.id },
                       "prose typed into a shell is a command")
        XCTAssertTrue(entries.contains { $0.nodeID == manager.id },
                      "its manager is told it is a terminal, though")
        let toManager = try XCTUnwrap(entries.first { $0.nodeID == manager.id })
        XCTAssertTrue(toManager.payload.contains("do not message it"))
    }

    func testAnAgentThatIsNotRunningIsNotSentAnything() async throws {
        // Nothing bound at all: everything is "not started yet", and a starting
        // prompt will describe the team when it does start.
        await roster.observeState()
        rename(workers[0], to: "Renamed")
        await roster.reconcile()

        let entries = try await rosterEntries()
        XCTAssertTrue(entries.isEmpty)
    }

    // MARK: - Teams and agents that arrive later

    /// Re-stubs tmux so every node of the current team has a session, and binds
    /// them, as starting an agent by itself would.
    private func bindEverythingAgain() async throws {
        let topology = bench.model.workspace.topology(bench.topology.id)!
        bench.runner.stub("list-sessions", CommandResult(
            exitCode: 0,
            standardOutput: Fixture.output(topology.nodes.enumerated().map { index, node in
                ["$\(index)", node.sessionName, "1700", "0", "1"]
            })))
        bench.runner.stub("list-panes", CommandResult(
            exitCode: 0,
            standardOutput: Fixture.output(topology.nodes.enumerated().map { index, node in
                ["%\(index)", "$\(index)", node.sessionName, "@0", "9", "cat", "/tmp", "1", "1", "0"]
            })))
        for node in topology.nodes {
            _ = try await bench.model.runtime.adopt(
                sessionName: node.sessionName, nodeID: node.id, topology: topology, cli: node.cli)
        }
        await bench.model.refresh()
    }

    func testAnAgentAddedAfterMarmyStartedStillHearsAboutLaterChanges() async throws {
        try await prepare()

        // A worker added to a running team. Its manager is told; the worker
        // itself learns the team in its own starting prompt.
        var topology = bench.model.workspace.topology(bench.topology.id)!
        let extra = AgentNode(
            sessionName: "extra", displayName: "Extra", kind: .worker, roleTitle: "Extra hands",
            workingDirectory: bench.root.path, parentID: manager.id)
        topology.upsert(extra)
        bench.model.update(topology)
        await roster.reconcile()

        var entries = try await rosterEntries()
        XCTAssertTrue(entries.contains { $0.nodeID == manager.id })
        XCTAssertFalse(entries.contains { $0.nodeID == extra.id },
                       "it has not started yet, and its own prompt will describe the team")

        // It starts, and then something about its team changes.
        try await bindEverythingAgain()
        await roster.observeState()
        topology = bench.model.workspace.topology(bench.topology.id)!
        var updated = topology.node(extra.id)!
        updated.contactIDs = [workers[0].id]
        topology.upsert(updated)
        bench.model.update(topology)
        await roster.reconcile()

        entries = try await rosterEntries()
        let toExtra = try XCTUnwrap(entries.last { $0.nodeID == extra.id })
        XCTAssertTrue(toExtra.payload.contains(workers[0].displayName),
                      "an agent Marmy met later is told about its team like any other")
    }

    func testATeamCreatedAfterTheFirstRefreshIsPickedUp() async throws {
        try await prepare()

        var second = Topology(name: "Second team", nodes: [])
        let lead = AgentNode(
            sessionName: "second-lead", displayName: "Second Lead", kind: .manager,
            workingDirectory: bench.root.path)
        second.upsert(lead)
        bench.model.addTeam(second)
        await roster.reconcile()
        let none = try await rosterEntries()
        XCTAssertTrue(none.isEmpty, "nobody in it is running")

        // Its manager is running now, and a worker joins.
        second.upsert(AgentNode(
            sessionName: "second-worker", displayName: "Second Worker", kind: .worker,
            workingDirectory: bench.root.path, parentID: lead.id))
        bench.runner.stub("list-sessions", CommandResult(
            exitCode: 0, standardOutput: Fixture.output([["$8", "second-lead", "1700", "0", "1"]])))
        bench.runner.stub("list-panes", CommandResult(
            exitCode: 0,
            standardOutput: Fixture.output([
                ["%8", "$8", "second-lead", "@0", "9", "cat", "/tmp", "1", "1", "0"],
            ])))
        _ = try await bench.model.runtime.adopt(
            sessionName: "second-lead", nodeID: lead.id, topology: second, cli: .claude)
        await bench.model.refresh()
        await roster.observeState()
        bench.model.update(second)
        await roster.reconcile()

        let entries = try await rosterEntries()
        let toLead = try XCTUnwrap(entries.first { $0.nodeID == lead.id })
        XCTAssertTrue(toLead.payload.contains("Second Worker"),
                      "a team created after Marmy started is not stuck in silence")
    }

    // MARK: - The user's decisions

    func testSendingByHandAfterAFailureIsAFreshAttempt() async throws {
        try await prepare()
        rename(workers[0], to: "Renamed")
        await roster.reconcile()
        let waiting = try XCTUnwrap(roster.pendingItems(forNode: manager.id).first)
        _ = try await bench.model.runtime.journal.update(
            waiting.entry.id, status: .uncertain, detail: "stopped mid-send")
        await roster.observeState()

        await roster.sendNow(waiting.id)

        let all = try await rosterEntries()
        let original = try XCTUnwrap(all.first { $0.id == waiting.entry.id })
        XCTAssertEqual(original.status, .uncertain, "what became of the first attempt still stands")
        let retry = try XCTUnwrap(all.first { $0.previousAttemptID == waiting.entry.id })
        XCTAssertEqual(retry.payload, waiting.entry.payload)
    }

    func testDiscardingAnUncertainDeliveryDoesNotRewriteWhatHappened() async throws {
        try await prepare()
        rename(workers[0], to: "Renamed")
        await roster.reconcile()
        let waiting = try XCTUnwrap(roster.pendingItems(forNode: manager.id).first)
        _ = try await bench.model.runtime.journal.update(
            waiting.entry.id, status: .uncertain, detail: "stopped mid-send")
        await roster.observeState()

        await roster.discard(waiting.id)

        XCTAssertTrue(roster.pendingItems(forNode: manager.id).isEmpty, "off the screen")
        let stored = try await bench.model.runtime.journal.entry(id: waiting.entry.id)
        XCTAssertEqual(stored?.status, .uncertain,
                       "whether the agent got it is a fact, not something a button changes")
    }

    // MARK: - When even the record of a delivery cannot be kept

    func testADeliveryWhoseOutcomeCannotBeRecordedReadsAsUnconfirmed() async throws {
        try await prepare()
        rename(workers[0], to: "Renamed")
        await roster.reconcile()
        let waiting = try XCTUnwrap(roster.pendingItems(forNode: manager.id).first)

        // It goes out, and the disk will not take the record of it going.
        let runtimeDirectory = bench.root.appendingPathComponent("runtime").path
        bench.runner.beforeCall = { subcommand in
            guard subcommand == "send-keys" else { return }
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o500], ofItemAtPath: runtimeDirectory)
        }
        await roster.sendNow(waiting.id)
        bench.runner.beforeCall = nil
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: runtimeDirectory)

        let held = try XCTUnwrap(roster.pendingItems(forNode: manager.id).first)
        XCTAssertTrue(held.isUnconfirmed,
                      "an attempt that ended while still written down as being sent is not 'not sent'")
        XCTAssertFalse(held.isReplaceable, "and a newer description must not quietly bury it")
        XCTAssertEqual(held.hold, .needsUser)

        // Nothing resends it on Marmy's own initiative.
        let sent = bench.runner.calls(of: "paste-buffer").count
        await roster.observeState()
        rename(workers[0], to: "Renamed Again")
        await roster.reconcile()
        XCTAssertEqual(bench.runner.calls(of: "paste-buffer").count, sent)
        let stored = try await bench.model.runtime.journal.entry(id: waiting.entry.id)
        XCTAssertNotEqual(stored?.status, .prepared, "and it is not offered up as untried")
    }

    // MARK: - Across restarts

    func testUpdatesWaitingFromALastRunComeBack() async throws {
        try await prepare()
        rename(workers[0], to: "Renamed")
        await roster.reconcile()
        let waiting = try XCTUnwrap(roster.pendingItems(forNode: manager.id).first)

        // A fresh coordinator, as after a restart.
        let fresh = RosterCoordinator()
        fresh.attach(model: bench.model)
        await fresh.restorePending()

        let restored = try XCTUnwrap(fresh.pendingItems(forNode: manager.id).first)
        XCTAssertEqual(restored.entry.id, waiting.entry.id)
        XCTAssertEqual(restored.entry.payload, waiting.entry.payload, "the words are kept exactly")
    }

    func testSomethingCaughtMidSendComesBackAsUncertainAndIsNotResent() async throws {
        try await prepare()
        rename(workers[0], to: "Renamed")
        await roster.reconcile()
        let waiting = try XCTUnwrap(roster.pendingItems(forNode: manager.id).first)
        _ = try await bench.model.runtime.journal.update(waiting.entry.id, status: .sending)

        let fresh = RosterCoordinator()
        fresh.attach(model: bench.model)
        await fresh.restorePending()

        let restored = try XCTUnwrap(fresh.pendingItems(forNode: manager.id).first)
        XCTAssertEqual(restored.entry.status, .uncertain)
        XCTAssertTrue(restored.reason.contains("not known"))
        let before = bench.runner.calls(of: "paste-buffer").count
        await fresh.observeState()
        XCTAssertEqual(bench.runner.calls(of: "paste-buffer").count, before,
                       "never sent again on Marmy's own initiative")
    }

    func testAStaleUpdateFromALastRunIsReplacedByTheTeamAsItIsNow() async throws {
        try await prepare()
        rename(workers[0], to: "Renamed")
        await roster.reconcile()
        let waiting = try XCTUnwrap(roster.pendingItems(forNode: manager.id).first)

        // Marmy was closed. The team changed again before it opened.
        rename(workers[0], to: "Renamed While Away")

        let fresh = RosterCoordinator()
        fresh.attach(model: bench.model)
        await fresh.restorePending()
        await fresh.reconcile()

        let stored = try await bench.model.runtime.journal.entry(id: waiting.entry.id)
        XCTAssertEqual(stored?.status, .superseded, "the old description never goes out")
        let current = try XCTUnwrap(fresh.pendingItems(forNode: manager.id).last)
        XCTAssertTrue(current.entry.payload.contains("Renamed While Away"),
                      "what the manager is told is what is true now")
    }

    /// The parent's lifecycle reproduction, kept as it was written: restore,
    /// then the first look at the server, then a second.
    func testARestoredStaleUpdateSurvivesTheInitialStateRead() async throws {
        try await prepare()
        rename(workers[0], to: "Old Roster Name")
        await roster.reconcile()
        let waiting = try XCTUnwrap(roster.pendingItems(forNode: manager.id).first)
        rename(workers[0], to: "Current Roster Name")

        let fresh = RosterCoordinator()
        fresh.attach(model: bench.model)
        await fresh.restorePending()
        await fresh.observeState()
        await fresh.observeState()

        let stored = try await bench.model.runtime.journal.entry(id: waiting.id)
        XCTAssertEqual(stored?.status, .superseded)
        let current = try XCTUnwrap(fresh.pendingItems(forNode: manager.id).last)
        XCTAssertTrue(current.entry.payload.contains("Current Roster Name"),
                      "the manager is owed the team as it stands, not as it stood")
    }

    func testStartingAnAgentDropsWhatWasWaitingForThatAgent() async throws {
        try await prepare()
        rename(workers[0], to: "Renamed")
        await roster.reconcile()
        let waiting = try XCTUnwrap(roster.pendingItems(forNode: manager.id).first)

        // Its starting prompt describes the team, so an older description of it
        // is not worth sending.
        let topology = bench.model.workspace.topology(bench.topology.id)!
        roster.adoptBaseline(topology, nodeIDs: [manager.id])
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(roster.pendingItems(forNode: manager.id).isEmpty)
        let stored = try await bench.model.runtime.journal.entry(id: waiting.entry.id)
        XCTAssertEqual(stored?.status, .superseded)
    }

    func testStartingOneMissingWorkerLeavesTheManagerStillOwedItsUpdate() async throws {
        // A running team, an update queued for the manager, and then a single
        // new worker is started. Only the worker was told anything.
        try await prepare()
        var topology = bench.model.workspace.topology(bench.topology.id)!
        let extra = AgentNode(
            sessionName: "extra", displayName: "Extra", kind: .worker,
            workingDirectory: bench.root.path, parentID: manager.id)
        topology.upsert(extra)
        bench.model.update(topology)
        await roster.reconcile()
        let waiting = try XCTUnwrap(roster.pendingItems(forNode: manager.id).first)

        roster.adoptBaseline(
            bench.model.workspace.topology(bench.topology.id)!, nodeIDs: [extra.id])
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(roster.pendingItems(forNode: manager.id).count, 1,
                       "the manager was not started again and was told nothing")
        let stored = try await bench.model.runtime.journal.entry(id: waiting.entry.id)
        XCTAssertEqual(stored?.status, .prepared)

        // And the manager still hears about later changes.
        rename(workers[0], to: "Renamed Later")
        await roster.reconcile()
        let entries = try await rosterEntries()
        XCTAssertTrue(entries.contains { $0.nodeID == manager.id && $0.payload.contains("Renamed Later") })
    }

    func testDiscardingKeepsTheRecordAndStopsTheUpdate() async throws {
        try await prepare()
        rename(workers[0], to: "Renamed")
        await roster.reconcile()
        let waiting = try XCTUnwrap(roster.pendingItems(forNode: manager.id).first)

        await roster.discard(waiting.id)

        XCTAssertTrue(roster.pendingItems(forNode: manager.id).isEmpty)
        let stored = try await bench.model.runtime.journal.entry(id: waiting.entry.id)
        XCTAssertEqual(stored?.payload, waiting.entry.payload)
        XCTAssertEqual(stored?.status, .discarded)
    }
}
