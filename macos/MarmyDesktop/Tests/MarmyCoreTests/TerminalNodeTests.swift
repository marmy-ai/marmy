import XCTest
@testable import MarmyCore

/// A terminal node is a shell someone drives, not an agent Marmy talks to.
final class TerminalNodeTests: XCTestCase {

    private func node(_ cli: AgentCLI) -> AgentNode {
        AgentNode(
            sessionName: "harness", displayName: "Harness", kind: .worker,
            cli: cli, workingDirectory: "/tmp")
    }

    func testATerminalIsNotAnAgentMarmyWritesTo() {
        XCTAssertFalse(node(.terminal).acceptsAgentMessages)
        XCTAssertTrue(node(.claude).acceptsAgentMessages)
        XCTAssertTrue(node(.codex).acceptsAgentMessages)
    }

    func testATerminalHasNoModelToChoose() {
        XCTAssertFalse(AgentCLI.terminal.supportsModelChoice)
        XCTAssertEqual(node(.terminal).effectiveModelDescription, "shell")
        XCTAssertEqual(node(.claude).effectiveModelDescription, "CLI default")
    }

    func testATerminalNeedsNoRolePromptToBeValid() {
        var topology = Topology(name: "Team", nodes: [node(.terminal)])
        topology.nodes[0].promptTemplateID = nil

        let issues = TopologyValidator.validate(topology, promptTemplates: DefaultTemplates.promptTemplates())
        XCTAssertTrue(issues.errors.isEmpty)
        XCTAssertFalse(
            issues.contains { if case .unassignedPromptTemplate = $0.kind { return true } else { return false } },
            "a shell is not missing anything by having no role prompt")
    }

    func testAnAgentWithoutARolePromptIsStillWorthMentioning() {
        var topology = Topology(name: "Team", nodes: [node(.claude)])
        topology.nodes[0].promptTemplateID = nil

        let issues = TopologyValidator.validate(topology, promptTemplates: DefaultTemplates.promptTemplates())
        XCTAssertTrue(
            issues.contains { if case .unassignedPromptTemplate = $0.kind { return true } else { return false } })
    }

    func testTerminalNodesKeepTheirPlaceInTheGraph() throws {
        let managerID = UUID()
        var topology = Topology(name: "Team", nodes: [
            AgentNode(
                id: managerID, sessionName: "lead", displayName: "Lead", kind: .manager,
                cli: .claude, workingDirectory: "/tmp",
                promptTemplateID: DefaultTemplates.ID.managerPrompt),
            AgentNode(
                sessionName: "harness", displayName: "Harness", kind: .worker,
                cli: .terminal, workingDirectory: "/tmp", parentID: managerID),
        ])
        topology.linkContacts(topology.nodes[0].id, topology.nodes[1].id)

        XCTAssertEqual(topology.children(of: managerID).map(\.displayName), ["Harness"])
        XCTAssertEqual(topology.contacts(of: managerID).map(\.displayName), ["Harness"])
        XCTAssertTrue(
            TopologyValidator.validate(topology, promptTemplates: DefaultTemplates.promptTemplates())
                .errors.isEmpty)
    }

    func testAgentCLIsStillRoundTrip() throws {
        for cli in AgentCLI.allCases {
            let data = try JSONEncoder().encode(cli)
            XCTAssertEqual(try JSONDecoder().decode(AgentCLI.self, from: data), cli)
        }
        XCTAssertEqual(AgentCLI.terminal.rawValue, "terminal")
    }
}
