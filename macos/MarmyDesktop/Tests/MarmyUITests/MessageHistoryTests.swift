import XCTest
import MarmyCore
import MarmyRuntime
@testable import MarmyUI

/// What Marmy says about what it has told an agent.
@MainActor
final class MessageHistoryTests: XCTestCase {

    private var bench: TestBench!

    override func setUpWithError() throws {
        bench = try TestBench()
    }

    override func tearDownWithError() throws {
        bench.cleanUp()
    }

    private var manager: AgentNode { bench.topology.roots[0] }

    func testAnAdoptedSessionSaysItsEarlierHistoryIsUnknown() async throws {
        try await bench.bindEverything()   // adoption, not a launch
        await bench.env.loadMessages(for: manager.id)

        XCTAssertTrue(bench.env.isAdopted(manager.id))
        XCTAssertTrue(bench.env.priorHistoryIsUnknown(manager.id),
                      "it was running before Marmy saw it; what it was told is not known")
    }

    func testAnAgentThatIsNotRunningClaimsNoUnknownHistory() async throws {
        await bench.env.loadMessages(for: manager.id)
        XCTAssertFalse(bench.env.priorHistoryIsUnknown(manager.id))
    }

    func testHistoryIsTheExactTextThatWasSent() async throws {
        try await bench.bindEverything()
        let binding = try XCTUnwrap(bench.model.binding(for: manager.id))
        let server = try XCTUnwrap(bench.model.readout.server)
        let target = AgentRuntime.DeliveryTarget(
            sessionID: binding.sessionID, paneID: binding.paneID, server: server,
            generation: binding.generation)
        _ = try await bench.model.runtime.recordPrepared(
            "the exact words", kind: .rosterUpdate, toNode: manager.id,
            topologyID: bench.topology.id, expecting: target)

        await bench.env.loadMessages(for: manager.id)

        let entries = try XCTUnwrap(bench.env.messages[manager.id])
        XCTAssertEqual(entries.map(\.payload), ["the exact words"])
    }

    func testAWaitingUpdateIsCounted() async throws {
        try await bench.bindEverything()
        await bench.env.roster.observeState()
        var topology = bench.model.workspace.topology(bench.topology.id)!
        var node = topology.node(bench.topology.children(of: manager.id)[0].id)!
        node.displayName = "Renamed"
        topology.upsert(node)
        bench.model.update(topology)
        await bench.env.roster.reconcile()

        XCTAssertEqual(bench.env.unsettledMessageCount(manager.id), 1)
    }

    // MARK: - What the words say

    func testStatusesAreSaidWithoutClaimingTheAgentReadAnything() {
        XCTAssertEqual(NodeMessagesView.describe(.submitted), "delivered")
        XCTAssertEqual(NodeMessagesView.describe(.pasted), "put into the prompt, not sent")
        XCTAssertEqual(NodeMessagesView.describe(.uncertain), "delivery not confirmed")
        XCTAssertEqual(NodeMessagesView.describe(.discarded), "thrown away before it was sent")
    }

    func testAMessageSaysWhichTerminalItWentTo() {
        let generation = UUID()
        let entry = JournalEntry(
            kind: .launchPrompt, sessionName: "lead", sessionID: "$1", paneID: "%1",
            generation: generation, payload: "hello")

        let destination = NodeMessagesView.destination(of: entry)
        XCTAssertTrue(destination.contains("lead"))
        XCTAssertTrue(destination.contains("$1"))
        XCTAssertTrue(destination.contains("pane %1"))
        XCTAssertTrue(destination.contains(generation.uuidString.prefix(8).lowercased()))
    }

    func testAMessageWithNowhereRecordedSaysSo() {
        let entry = JournalEntry(
            kind: .launchPrompt, sessionName: "", sessionID: "", paneID: "", payload: "hello")
        XCTAssertEqual(NodeMessagesView.destination(of: entry), "no recorded destination")
    }
}
