import XCTest
import MarmyCore
@testable import MarmyRuntime

final class BootstrapPromptTests: XCTestCase {

    private let workspace = Team.workspace(workingDirectory: "/tmp")
    private var topology: Topology { Team.topology(workingDirectory: "/tmp") }

    func testTheWorkerIsToldWhereItsManagerIsAndToWait() throws {
        let text = try BootstrapPrompt.render(
            for: topology.nodes[1], in: topology, workspace: workspace)

        XCTAssertTrue(text.contains("You are Build"))
        XCTAssertTrue(text.contains("You are in tmux session build on this Mac."))
        XCTAssertTrue(text.contains("Lead — your manager, tmux session lead"))
        XCTAssertTrue(text.contains("Wait for your first assignment from Lead."))
        XCTAssertTrue(text.contains("After you finish an assignment, report it and wait."))
    }

    func testAddressingUsesPaneTargetSyntaxForSessionNames() throws {
        let text = try BootstrapPrompt.render(
            for: topology.nodes[1], in: topology, workspace: workspace)
        // send-keys resolves -t as a pane target, so a bare session name fails.
        XCTAssertTrue(text.contains("send-keys -t =<session>: -l"))
        XCTAssertTrue(text.contains("send-keys -t =<session>: Enter"))
    }

    func testACustomSocketAppearsInTheInstructions() throws {
        let text = try BootstrapPrompt.render(
            for: topology.nodes[0], in: topology, workspace: workspace,
            server: .named("marmy-test", configFile: "/dev/null"))
        XCTAssertTrue(text.contains("tmux -L marmy-test send-keys"))
        XCTAssertFalse(text.contains("/dev/null"), "a test config file is not the agent's business")
    }

    func testOnlyPermittedPeersAreListed() {
        var topology = self.topology
        let stranger = AgentNode(
            id: UUID(), sessionName: "stranger", displayName: "Stranger", kind: .worker,
            workingDirectory: "/tmp", parentID: Team.managerID)
        topology.upsert(stranger)

        let addresses = BootstrapPrompt.addresses(for: topology.nodes[1], in: topology)
        XCTAssertEqual(addresses.map(\.displayName), ["Lead"])
        XCTAssertFalse(addresses.contains { $0.displayName == "Stranger" })
    }

    func testManagerListsReportsAndExplicitContacts() {
        var topology = self.topology
        let peer = AgentNode(
            id: UUID(), sessionName: "research", displayName: "Research", kind: .manager,
            workingDirectory: "/tmp")
        topology.upsert(peer)
        topology.linkContacts(Team.managerID, peer.id)

        let addresses = BootstrapPrompt.addresses(for: topology.nodes[0], in: topology)
        XCTAssertEqual(addresses.map(\.relationship), ["your report", "permitted contact"])
        XCTAssertEqual(addresses.map(\.displayName), ["Build", "Research"])
    }

    func testAnAdoptedPeerIsAddressedByItsRealSessionName() throws {
        let names: [UUID: String] = [Team.managerID: "marmy_worker_opus", Team.workerID: "build"]
        let text = try BootstrapPrompt.render(
            for: topology.nodes[1], in: topology, workspace: workspace, resolvedSessionNames: names)

        XCTAssertTrue(text.contains("tmux session marmy_worker_opus"))
        XCTAssertTrue(text.contains("an existing session attached to this team; not lead"))
        XCTAssertFalse(text.contains("tmux session lead"))
    }

    func testAnAgentWithNobodyToTalkToIsToldSo() throws {
        var solo = Topology(id: UUID(), name: "Solo", nodes: [AgentNode(
            id: UUID(), sessionName: "solo", displayName: "Solo", kind: .manager,
            workingDirectory: "/tmp", promptTemplateID: DefaultTemplates.ID.soloPrompt)])
        solo.pruneDanglingReferences()

        let text = try BootstrapPrompt.render(for: solo.nodes[0], in: solo, workspace: workspace)
        XCTAssertTrue(text.contains("No other agent is reachable from here."))
    }

    func testNodesWithoutATemplateStillGetAddressing() throws {
        var topology = self.topology
        topology.nodes[1].promptTemplateID = nil
        let text = try BootstrapPrompt.render(
            for: topology.nodes[1], in: topology, workspace: workspace)

        XCTAssertTrue(text.hasPrefix("Reaching other agents"))
        XCTAssertTrue(text.contains("tmux session lead"))
    }
}
