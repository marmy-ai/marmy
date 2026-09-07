import XCTest
@testable import MarmyCore

/// Navigation across every saved team.
final class WorkspaceNavigatorTests: XCTestCase {

    private func team(_ index: Int, roots: Int, workersPerRoot: Int) -> Topology {
        var nodes: [AgentNode] = []
        for root in 0..<roots {
            let manager = AgentNode(
                id: makeID(index * 100 + root * 10),
                sessionName: "t\(index)-lead\(root)",
                displayName: "Team \(index) lead \(root)",
                kind: .manager,
                workingDirectory: "/tmp")
            nodes.append(manager)
            for worker in 0..<workersPerRoot {
                nodes.append(AgentNode(
                    id: makeID(index * 100 + root * 10 + worker + 1),
                    sessionName: "t\(index)-w\(root)\(worker)",
                    displayName: "Team \(index) worker \(root)\(worker)",
                    kind: .worker,
                    workingDirectory: "/tmp",
                    parentID: manager.id))
            }
        }
        return Topology(id: makeID(index * 1000), name: "Team \(index)", nodes: nodes)
    }

    private func location(_ topology: Topology, _ nodeID: UUID) -> AgentLocation {
        AgentLocation(topologyID: topology.id, nodeID: nodeID)
    }

    // MARK: - Root layer

    func testRootsFromEveryTeamArePeers() {
        let first = team(1, roots: 1, workersPerRoot: 2)
        let second = team(2, roots: 1, workersPerRoot: 1)
        let topologies = [first, second]

        let peers = WorkspaceNavigator.peers(
            of: location(first, first.roots[0].id), in: topologies)

        XCTAssertEqual(peers.map(\.nodeID), [first.roots[0].id, second.roots[0].id])
    }

    func testCyclingAtTheRootLayerCrossesTeamsAndWraps() {
        let first = team(1, roots: 1, workersPerRoot: 1)
        let second = team(2, roots: 1, workersPerRoot: 1)
        let third = team(3, roots: 1, workersPerRoot: 1)
        let topologies = [first, second, third]

        var current = location(first, first.roots[0].id)
        for expected in [second.roots[0].id, third.roots[0].id, first.roots[0].id] {
            current = WorkspaceNavigator.destination(for: .nextPeer, from: current, in: topologies)!
            XCTAssertEqual(current.nodeID, expected)
        }
    }

    func testCyclingBackwardsWrapsTheOtherWay() {
        let first = team(1, roots: 1, workersPerRoot: 1)
        let second = team(2, roots: 1, workersPerRoot: 1)
        let topologies = [first, second]

        let back = WorkspaceNavigator.destination(
            for: .previousPeer, from: location(first, first.roots[0].id), in: topologies)
        XCTAssertEqual(back?.nodeID, second.roots[0].id)
        XCTAssertEqual(back?.topologyID, second.id)
    }

    func testARootWorkerIsAPeerOfTheRootManagers() {
        var first = team(1, roots: 1, workersPerRoot: 1)
        let stray = AgentNode(
            id: makeID(999), sessionName: "stray", displayName: "Stray", kind: .worker,
            workingDirectory: "/tmp")
        first.upsert(stray)
        let topologies = [first, team(2, roots: 1, workersPerRoot: 0)]

        let peers = WorkspaceNavigator.peers(of: location(first, stray.id), in: topologies)
        XCTAssertTrue(peers.contains { $0.nodeID == stray.id }, "no agent may be unreachable")
        XCTAssertEqual(peers.count, 3)
    }

    // MARK: - Report layer

    func testReportsCycleOnlyAmongTheirOwnSiblings() {
        let first = team(1, roots: 2, workersPerRoot: 2)
        let second = team(2, roots: 1, workersPerRoot: 2)
        let topologies = [first, second]

        let firstManager = first.roots[0]
        let siblings = first.children(of: firstManager.id)
        let peers = WorkspaceNavigator.peers(of: location(first, siblings[0].id), in: topologies)

        XCTAssertEqual(peers.map(\.nodeID), siblings.map(\.id))
        let next = WorkspaceNavigator.destination(
            for: .nextPeer, from: location(first, siblings[1].id), in: topologies)
        XCTAssertEqual(next?.nodeID, siblings[0].id, "cycling wraps inside the manager's own reports")
    }

    func testANestedManagerIsAPeerOfItsSiblingsUntilItBecomesARoot() throws {
        var first = team(1, roots: 1, workersPerRoot: 1)
        let root = first.roots[0]
        var nested = AgentNode(
            id: makeID(555), sessionName: "nested", displayName: "Nested lead", kind: .manager,
            workingDirectory: "/tmp", parentID: root.id)
        first.upsert(nested)
        let second = team(2, roots: 1, workersPerRoot: 0)

        var peers = WorkspaceNavigator.peers(of: location(first, nested.id), in: [first, second])
        XCTAssertEqual(Set(peers.map(\.nodeID)), Set(first.children(of: root.id).map(\.id)))
        XCTAssertFalse(peers.contains { $0.nodeID == second.roots[0].id })

        try first.reparent(nested.id, to: nil)
        nested = first.node(nested.id)!
        peers = WorkspaceNavigator.peers(of: location(first, nested.id), in: [first, second])
        XCTAssertTrue(peers.contains { $0.nodeID == second.roots[0].id },
                      "at the root layer it joins the global cycle")
    }

    // MARK: - Up and down

    func testUpAndDownStayInsideTheTeam() {
        let first = team(1, roots: 1, workersPerRoot: 2)
        let topologies = [first, team(2, roots: 1, workersPerRoot: 1)]
        let manager = first.roots[0]
        let workers = first.children(of: manager.id)

        let up = WorkspaceNavigator.destination(
            for: .parent, from: location(first, workers[1].id), in: topologies)
        XCTAssertEqual(up?.nodeID, manager.id)

        let down = WorkspaceNavigator.destination(
            for: .child, from: location(first, manager.id), in: topologies,
            rememberedChildren: [manager.id: workers[1].id])
        XCTAssertEqual(down?.nodeID, workers[1].id, "it returns to the report you were in")

        let firstChild = WorkspaceNavigator.destination(
            for: .child, from: location(first, manager.id), in: topologies)
        XCTAssertEqual(firstChild?.nodeID, workers[0].id)
    }

    func testMovesWithNowhereToGoStayPut() {
        let first = team(1, roots: 1, workersPerRoot: 1)
        let topologies = [first]
        let worker = first.children(of: first.roots[0].id)[0]

        XCTAssertEqual(
            WorkspaceNavigator.destination(for: .child, from: location(first, worker.id), in: topologies)?.nodeID,
            worker.id)
        XCTAssertEqual(
            WorkspaceNavigator.destination(
                for: .parent, from: location(first, first.roots[0].id), in: topologies)?.nodeID,
            first.roots[0].id)
    }

    // MARK: - Things that have gone away

    func testAMissingSelectionFallsBackToTheFirstRootAnywhere() {
        let first = team(1, roots: 1, workersPerRoot: 1)
        let gone = AgentLocation(topologyID: first.id, nodeID: makeID(4242))

        let destination = WorkspaceNavigator.destination(for: .nextPeer, from: gone, in: [first])
        XCTAssertEqual(destination?.nodeID, first.roots[0].id)
    }

    func testASelectionInADeletedTeamFallsBackToWhatIsLeft() {
        let first = team(1, roots: 1, workersPerRoot: 1)
        let second = team(2, roots: 1, workersPerRoot: 1)
        let stale = AgentLocation(topologyID: second.id, nodeID: second.roots[0].id)

        let destination = WorkspaceNavigator.destination(for: .nextPeer, from: stale, in: [first])
        XCTAssertEqual(destination?.topologyID, first.id)
    }

    func testNoTeamsAtAllIsHarmless() {
        XCTAssertNil(WorkspaceNavigator.destination(for: .nextPeer, from: nil, in: []))
        XCTAssertTrue(WorkspaceNavigator.roots(in: []).isEmpty)
    }

    func testSelectingByIdFindsTheTeamItBelongsTo() {
        let first = team(1, roots: 1, workersPerRoot: 1)
        let second = team(2, roots: 1, workersPerRoot: 1)
        let target = second.children(of: second.roots[0].id)[0]

        let destination = WorkspaceNavigator.destination(
            for: .select(target.id), from: location(first, first.roots[0].id), in: [first, second])
        XCTAssertEqual(destination, AgentLocation(topologyID: second.id, nodeID: target.id))
    }
}
