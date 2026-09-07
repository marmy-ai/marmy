import XCTest
@testable import MarmyCore

final class TopologyValidatorTests: XCTestCase {

    private let templates = DefaultTemplates.promptTemplates()

    private func team() -> Topology {
        Fixtures.team(promptTemplateID: DefaultTemplates.ID.workerPrompt)
    }

    func testValidTeamHasNoErrors() {
        let issues = TopologyValidator.validate(team(), promptTemplates: templates)
        XCTAssertTrue(issues.errors.isEmpty, "unexpected: \(issues.errors.map(\.message))")
        XCTAssertTrue(issues.isLaunchable)
    }

    func testEmptyTopologyNameAndNoNodes() {
        let issues = TopologyValidator.validate(Topology(name: "  "))
        XCTAssertTrue(issues.contains { $0.kind == .emptyTopologyName })
        XCTAssertTrue(issues.contains { $0.kind == .noNodes })
    }

    func testInvalidAndDuplicateSessionNames() {
        var topology = team()
        topology.nodes[1].sessionName = "bad name"
        topology.nodes[2].sessionName = "lead"
        let issues = TopologyValidator.validate(topology, promptTemplates: templates)

        XCTAssertTrue(issues.contains {
            if case .invalidSessionName(let nodeID, _, _) = $0.kind { return nodeID == Fixtures.workerAID }
            return false
        })
        XCTAssertTrue(issues.contains {
            if case .duplicateSessionName(let name, let ids) = $0.kind {
                return name == "lead" && ids.count == 2
            }
            return false
        })
        XCTAssertFalse(issues.isLaunchable)
    }

    func testMissingParentAndSelfParenting() {
        var topology = team()
        topology.nodes[1].parentID = makeID(777)
        topology.nodes[2].parentID = Fixtures.workerBID
        let issues = TopologyValidator.validate(topology, promptTemplates: templates)

        XCTAssertTrue(issues.contains { $0.kind == .missingParent(nodeID: Fixtures.workerAID, parentID: makeID(777)) })
        XCTAssertTrue(issues.contains { $0.kind == .selfParent(nodeID: Fixtures.workerBID) })
    }

    func testAWorkerMayTakeReports() {
        // Manager and worker say what someone does, not who may supervise.
        var topology = team()
        topology.nodes[0].kind = .worker
        let issues = TopologyValidator.validate(topology, promptTemplates: templates)

        XCTAssertTrue(issues.filter { $0.severity == .error }.isEmpty, "\(issues.map(\.message))")
        XCTAssertTrue(issues.isEmpty, "a team of workers is a team: \(issues.map(\.message))")
    }

    func testDeepReportingCycleIsReportedOnce() {
        var nodes = (1...4).map { Fixtures.node($0, kind: .manager, session: "m\($0)") }
        nodes[0].parentID = nodes[3].id
        nodes[1].parentID = nodes[0].id
        nodes[2].parentID = nodes[1].id
        nodes[3].parentID = nodes[2].id
        let topology = Topology(name: "Loop", nodes: nodes)

        let cycles = TopologyValidator.validate(topology).compactMap { issue -> [UUID]? in
            if case .reportingCycle(let ids) = issue.kind { return ids }
            return nil
        }
        XCTAssertEqual(cycles.count, 1)
        XCTAssertEqual(Set(cycles[0]), Set(nodes.map(\.id)))
        XCTAssertEqual(cycles[0].first, nodes[0].id, "a loop is reported from its first member in topology order")
    }

    func testTwoNodeCycleIsReportedOnce() {
        var a = Fixtures.node(1, kind: .manager, session: "a")
        var b = Fixtures.node(2, kind: .manager, session: "b")
        a.parentID = b.id
        b.parentID = a.id
        let issues = TopologyValidator.validate(Topology(name: "Pair", nodes: [a, b]))
        XCTAssertEqual(issues.filter {
            if case .reportingCycle = $0.kind { return true }
            return false
        }.count, 1)
    }

    func testMissingContactAndSelfContact() {
        var topology = team()
        topology.nodes[1].contactIDs = [makeID(555), Fixtures.workerAID]
        let issues = TopologyValidator.validate(topology, promptTemplates: templates)

        XCTAssertTrue(issues.contains {
            $0.kind == .missingContact(nodeID: Fixtures.workerAID, contactID: makeID(555))
        })
        XCTAssertTrue(issues.contains { $0.kind == .selfContact(nodeID: Fixtures.workerAID) })
    }

    func testWorkingDirectoryMustBeAbsolute() {
        var topology = team()
        topology.nodes[0].workingDirectory = ""
        topology.nodes[1].workingDirectory = "relative/path"
        topology.nodes[2].workingDirectory = "~/code"
        let issues = TopologyValidator.validate(topology, promptTemplates: templates)

        XCTAssertTrue(issues.contains { $0.kind == .emptyWorkingDirectory(nodeID: Fixtures.managerID) })
        XCTAssertTrue(issues.contains {
            $0.kind == .relativeWorkingDirectory(nodeID: Fixtures.workerAID, path: "relative/path")
        })
        XCTAssertFalse(issues.contains { $0.nodeID == Fixtures.workerBID && $0.severity == .error })
    }

    func testMissingAndUnassignedPromptTemplates() {
        var topology = team()
        topology.nodes[1].promptTemplateID = makeID(444)
        topology.nodes[2].promptTemplateID = nil
        let issues = TopologyValidator.validate(topology, promptTemplates: templates)

        XCTAssertTrue(issues.contains {
            $0.kind == .missingPromptTemplate(nodeID: Fixtures.workerAID, templateID: makeID(444))
        })
        XCTAssertTrue(issues.contains { $0.kind == .unassignedPromptTemplate(nodeID: Fixtures.workerBID) })
        XCTAssertEqual(
            issues.first { $0.kind == .unassignedPromptTemplate(nodeID: Fixtures.workerBID) }?.severity,
            .warning,
            "a missing role prompt is worth saying, but it does not block a launch")
    }

    func testMalformedTemplateVariableIsAnError() {
        let bad = PromptTemplate(
            id: makeID(300),
            name: "Broken",
            body: "Hello {{agent.nmae}}")
        var topology = team()
        topology.nodes[0].promptTemplateID = bad.id

        let issues = TopologyValidator.validate(topology, promptTemplates: templates + [bad])
        XCTAssertTrue(issues.contains {
            $0.kind == .malformedPromptVariable(templateID: bad.id, variable: "agent.nmae")
        })
    }

    func testMalformedTemplateSyntaxIsAnError() {
        let bad = PromptTemplate(id: makeID(301), name: "Broken", body: "{{#reports}}oops")
        XCTAssertEqual(TopologyValidator.validate(template: bad).count, 1)
        XCTAssertEqual(TopologyValidator.validate(template: bad).first?.severity, .error)
    }

    func testDuplicateNodeIdentity() {
        var topology = team()
        topology.nodes.append(topology.nodes[1])
        let issues = TopologyValidator.validate(topology, promptTemplates: templates)
        XCTAssertTrue(issues.contains { $0.kind == .duplicateNodeID(Fixtures.workerAID) })
    }

    func testIssuesAreOrderedErrorsFirst() {
        var topology = team()
        topology.nodes[2].promptTemplateID = nil        // warning
        topology.nodes[0].workingDirectory = ""         // error
        let issues = TopologyValidator.validate(topology, promptTemplates: templates)
        XCTAssertEqual(issues.first?.severity, .error)
        XCTAssertEqual(issues.last?.severity, .warning)
    }
}
