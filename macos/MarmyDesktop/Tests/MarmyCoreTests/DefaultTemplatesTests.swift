import XCTest
@testable import MarmyCore

final class DefaultTemplatesTests: XCTestCase {

    func testShippedPromptTemplatesAreValid() {
        for template in DefaultTemplates.promptTemplates() {
            XCTAssertTrue(
                TopologyValidator.validate(template: template).isEmpty,
                "\(template.name): \(TopologyValidator.validate(template: template).map(\.message))")
        }
    }

    func testShippedTopologyTemplatesValidateAndLaunch() {
        let workspace = Workspace.starter()
        for template in workspace.topologyTemplates {
            let issues = TopologyValidator.validate(
                template.prototype, promptTemplates: workspace.promptTemplates)
            XCTAssertTrue(issues.errors.isEmpty, "\(template.name): \(issues.errors.map(\.message))")
            XCTAssertTrue(issues.isLaunchable)
        }
    }

    func testWorkerPromptTellsTheWorkerToWaitForItsNamedManager() throws {
        let workspace = Workspace.starter()
        let team = workspace.topologyTemplate(DefaultTemplates.ID.starterTeam)!.prototype
        let worker = team.nodes[1]
        let rendered = try PromptRenderer.render(
            template: workspace.promptTemplate(DefaultTemplates.ID.workerPrompt)!,
            for: worker, in: team, operatorName: "Marwan")

        XCTAssertTrue(rendered.contains("Right now: do not start any work."))
        XCTAssertTrue(rendered.contains("Wait for your first assignment from Lead."))
        XCTAssertTrue(rendered.contains("You report to Lead, in tmux session lead."))
        XCTAssertTrue(rendered.contains("Never run git add, commit, push"))
        XCTAssertTrue(rendered.contains("you may talk to: Verify (verify). Do not contact anyone else."))
    }

    func testWorkerWithoutContactsStillGetsAContactRestriction() throws {
        let workspace = Workspace.starter()
        var team = workspace.topologyTemplate(DefaultTemplates.ID.pairTeam)!.prototype
        team.nodes[1].contactIDs = []
        let rendered = try PromptRenderer.render(
            template: workspace.promptTemplate(DefaultTemplates.ID.workerPrompt)!,
            for: team.nodes[1], in: team, operatorName: "Marwan")

        XCTAssertTrue(rendered.contains("You have no other permitted contacts: talk only to Lead."))
        XCTAssertTrue(rendered.contains("Do not message any other agent or session."))
    }

    func testManagerWithoutContactsMayStillTalkToItsOwnManager() throws {
        // A nested manager is told to report upward, so the contact rules have to
        // permit that parent even when no extra contacts are configured.
        let workspace = Workspace.starter()
        var team = workspace.topologyTemplate(DefaultTemplates.ID.starterTeam)!.prototype
        let director = AgentNode(
            id: makeID(500), sessionName: "director", displayName: "Director", kind: .manager,
            workingDirectory: "/tmp/marmy-tests", promptTemplateID: DefaultTemplates.ID.managerPrompt)
        team.upsert(director)
        try team.reparent(team.nodes[0].id, to: director.id)

        let rendered = try PromptRenderer.render(
            template: workspace.promptTemplate(DefaultTemplates.ID.managerPrompt)!,
            for: team.nodes[0], in: team, operatorName: "Marwan")

        XCTAssertTrue(rendered.contains("You report to Director, in tmux session director."))
        XCTAssertTrue(rendered.contains("Talk only to your own reports and to Director."))
        XCTAssertTrue(rendered.contains("Wait for Director to give you the goal."))
        XCTAssertFalse(rendered.contains("Talk only to your own reports and to Marwan."))
    }

    func testManagerWithContactsStillNamesItsOwnManager() throws {
        let workspace = Workspace.starter()
        var team = workspace.topologyTemplate(DefaultTemplates.ID.starterTeam)!.prototype
        let director = AgentNode(
            id: makeID(501), sessionName: "director", displayName: "Director", kind: .manager,
            workingDirectory: "/tmp/marmy-tests", promptTemplateID: DefaultTemplates.ID.managerPrompt)
        let peer = AgentNode(
            id: makeID(502), sessionName: "research", displayName: "Research", kind: .manager,
            workingDirectory: "/tmp/marmy-tests", parentID: makeID(501),
            promptTemplateID: DefaultTemplates.ID.managerPrompt)
        team.upsert(director)
        team.upsert(peer)
        try team.reparent(team.nodes[0].id, to: director.id)
        team.linkContacts(team.nodes[0].id, peer.id)

        let rendered = try PromptRenderer.render(
            template: workspace.promptTemplate(DefaultTemplates.ID.managerPrompt)!,
            for: team.nodes[0], in: team, operatorName: "Marwan")

        XCTAssertTrue(rendered.contains("Besides your reports and Director, you may talk to:"))
        XCTAssertTrue(rendered.contains("Research (research)"))
    }

    func testRootManagerWithoutContactsFallsBackToItsHuman() throws {
        let workspace = Workspace.starter()
        let team = workspace.topologyTemplate(DefaultTemplates.ID.pairTeam)!.prototype
        let rendered = try PromptRenderer.render(
            template: workspace.promptTemplate(DefaultTemplates.ID.managerPrompt)!,
            for: team.nodes[0], in: team, operatorName: "Marwan")
        XCTAssertTrue(rendered.contains("Talk only to your own reports and to Marwan."))
    }

    func testManagerPromptWaitsForItsHumanThenWorksAutonomously() throws {
        let workspace = Workspace.starter()
        let team = workspace.topologyTemplate(DefaultTemplates.ID.starterTeam)!.prototype
        let rendered = try PromptRenderer.render(
            template: workspace.promptTemplate(DefaultTemplates.ID.managerPrompt)!,
            for: team.nodes[0], in: team, operatorName: "Marwan")

        XCTAssertTrue(rendered.contains("Wait for Marwan to give you the goal."))
        XCTAssertTrue(rendered.contains("Carry an assigned goal through to completion on your own."))
        XCTAssertTrue(rendered.contains("Do not ask Marwan to approve each step."))
        XCTAssertTrue(rendered.contains("Interrupt Marwan only when the goal is done"))
        XCTAssertTrue(rendered.contains("- Build — Worker, tmux session build"))
        XCTAssertTrue(rendered.contains("You own git for this team"))
    }

    func testStarterWorkspaceShipsBothTemplateKinds() {
        let workspace = Workspace.starter()
        XCTAssertEqual(workspace.promptTemplates.count, 3)
        XCTAssertEqual(workspace.topologyTemplates.count, 2)
        XCTAssertTrue(workspace.topologies.isEmpty)
        XCTAssertTrue(workspace.promptTemplates.allSatisfy(\.isBuiltIn))
    }
}
