import XCTest
@testable import MarmyCore

final class DefaultAgentNamingTests: XCTestCase {

    private func team(names: [(String, AgentKind)]) -> Topology {
        Topology(name: "Team", nodes: names.enumerated().map { index, entry in
            AgentNode(
                id: makeID(index + 1),
                sessionName: "s\(index)",
                displayName: entry.0,
                kind: entry.1,
                workingDirectory: "/tmp")
        })
    }

    func testEachNewAgentGetsItsOwnNumber() {
        var topology = team(names: [])
        for expected in ["Worker 1", "Worker 2", "Worker 3"] {
            let name = DefaultAgentNaming.nextDisplayName(for: .worker, in: topology)
            XCTAssertEqual(name, expected)
            topology.upsert(AgentNode(
                sessionName: TmuxName.sanitize(name), displayName: name, kind: .worker,
                workingDirectory: "/tmp"))
        }
        XCTAssertEqual(DefaultAgentNaming.nextDisplayName(for: .manager, in: topology), "Manager 1")
    }

    func testItSkipsNamesThatCameFromATemplateOrTheUser() {
        let topology = team(names: [("Worker 1", .worker), ("Worker 2", .worker), ("Lead", .manager)])
        XCTAssertEqual(DefaultAgentNaming.nextDisplayName(for: .worker, in: topology), "Worker 3")
        XCTAssertEqual(DefaultAgentNaming.nextDisplayName(for: .manager, in: topology), "Manager 1")
    }

    func testAFreedNumberIsUsedAgain() {
        var topology = team(names: [("Worker 1", .worker), ("Worker 2", .worker)])
        topology.remove(topology.nodes[0].id)
        XCTAssertEqual(DefaultAgentNaming.nextDisplayName(for: .worker, in: topology), "Worker 1")
    }

    func testRenamedAgentsAreLeftAlone() {
        let topology = team(names: [("Docs reviewer", .worker), ("Worker 2", .worker)])
        // Nothing is renumbered; the next default simply avoids what is taken.
        XCTAssertEqual(DefaultAgentNaming.nextDisplayName(for: .worker, in: topology), "Worker 1")
        XCTAssertEqual(topology.nodes[0].displayName, "Docs reviewer")
    }

    func testSessionNamesFollowTheDisplayNameAndStayFree() {
        XCTAssertEqual(DefaultAgentNaming.sessionName(for: "Worker 1", avoiding: []), "worker-1")
        XCTAssertEqual(
            DefaultAgentNaming.sessionName(for: "Worker 1", avoiding: ["worker-1"]),
            "worker-1-2")
        XCTAssertTrue(TmuxName.isValid(DefaultAgentNaming.sessionName(for: "Manager 12", avoiding: [])))
    }

    func testItKnowsWhichNamesItGenerated() {
        XCTAssertTrue(DefaultAgentNaming.isGeneratedPlaceholder("Worker 3"))
        XCTAssertTrue(DefaultAgentNaming.isGeneratedPlaceholder("Manager 1"))
        XCTAssertTrue(DefaultAgentNaming.isGeneratedPlaceholder("New worker"))
        XCTAssertFalse(DefaultAgentNaming.isGeneratedPlaceholder("Worker bee"))
        XCTAssertFalse(DefaultAgentNaming.isGeneratedPlaceholder("Docs reviewer"))
    }
}
