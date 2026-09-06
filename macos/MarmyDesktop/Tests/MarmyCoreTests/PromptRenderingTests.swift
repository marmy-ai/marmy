import XCTest
@testable import MarmyCore

final class PromptRenderingTests: XCTestCase {

    func testContextDescribesTheAgentItsManagerReportsAndContacts() {
        let team = Fixtures.team(name: "Mac work")
        let worker = team.node(Fixtures.workerAID)!
        let context = PromptVariables.context(for: worker, in: team, operatorName: "Marwan")

        XCTAssertEqual(context["agent.name"], "Build")
        XCTAssertEqual(context["agent.session"], "build")
        XCTAssertEqual(context["agent.kind"], "Worker")
        XCTAssertEqual(context["agent.cli"], "Claude Code")
        XCTAssertEqual(context["agent.model"], "", "a blank model means the CLI default, not an invented id")
        XCTAssertEqual(context["agent.cwd"], "/tmp/marmy-tests")
        XCTAssertEqual(context["manager.name"], "Lead")
        XCTAssertEqual(context["manager.session"], "lead")
        XCTAssertEqual(context["contacts"], "Verify (verify)")
        XCTAssertEqual(context["topology.name"], "Mac work")
        XCTAssertEqual(context["human.name"], "Marwan")
        XCTAssertEqual(context["reports"], "")
    }

    func testEveryDocumentedVariableIsAlwaysDefined() {
        let team = Fixtures.team()
        let context = PromptVariables.context(for: team.nodes[0], in: team)
        for key in PromptVariables.allKeys {
            XCTAssertNotNil(context[key], "missing variable \(key)")
        }
        XCTAssertEqual(context["human.name"], "your human", "a blank operator name still reads as a person")
    }

    func testManagerContextListsReportsInTopologyOrder() {
        let team = Fixtures.team()
        let context = PromptVariables.context(for: team.nodes[0], in: team)
        XCTAssertEqual(context["reports"], "Build (build), Verify (verify)")
        XCTAssertEqual(context["reports.list"], """
        - Build — Worker, tmux session build
        - Verify — Worker, tmux session verify
        """)
    }

    func testAddressesUseTheAttachedSessionWhenThereIsOne() {
        var team = Fixtures.team()
        team.nodes[0].attachedSessionName = "existing_lead"
        team.nodes[1].attachedSessionName = "existing_build"

        let workerContext = PromptVariables.context(for: team.nodes[1], in: team)
        XCTAssertEqual(workerContext["agent.session"], "existing_build")
        XCTAssertEqual(workerContext["manager.session"], "existing_lead")

        let managerContext = PromptVariables.context(for: team.nodes[0], in: team)
        XCTAssertEqual(managerContext["reports"], "Build (existing_build), Verify (verify)")
        XCTAssertTrue(managerContext["reports.list"]!.contains("tmux session existing_build"))

        let peerContext = PromptVariables.context(for: team.nodes[2], in: team)
        XCTAssertEqual(peerContext["contacts"], "Build (existing_build)")
    }

    func testAgentNotesAreAppendedWhenTheTemplateDoesNotUseThem() throws {
        var team = Fixtures.team()
        team.nodes[1].notes = "Only touch macos/MarmyDesktop."
        let template = PromptTemplate(name: "Terse", body: "You are {{agent.name}}.")

        let rendered = try PromptRenderer.render(template: template, for: team.nodes[1], in: team)
        XCTAssertEqual(rendered, "You are Build.\n\nOnly touch macos/MarmyDesktop.\n")
    }

    func testAgentNotesAreNotDuplicatedWhenTheTemplatePlacesThem() throws {
        var team = Fixtures.team()
        team.nodes[1].notes = "Only touch macos/MarmyDesktop."
        let template = PromptTemplate(name: "Placed", body: "Notes: {{agent.notes}}")

        let rendered = try PromptRenderer.render(template: template, for: team.nodes[1], in: team)
        XCTAssertEqual(rendered, "Notes: Only touch macos/MarmyDesktop.")
    }

    func testRenderAllSkipsNodesWithoutATemplate() throws {
        var team = Fixtures.team(promptTemplateID: DefaultTemplates.ID.workerPrompt)
        team.nodes[2].promptTemplateID = nil

        let rendered = try PromptRenderer.renderAll(
            in: team,
            templates: DefaultTemplates.promptTemplates(),
            operatorName: "Marwan")
        XCTAssertEqual(rendered.map(\.node.sessionName), ["lead", "build"])
    }
}
