import XCTest
@testable import MarmyCore

final class NavigationTests: XCTestCase {

    /// Two root managers, each with two workers.
    private func twoTeams() -> Topology {
        Topology(name: "Two teams", nodes: [
            Fixtures.node(1, kind: .manager, session: "lead1"),
            Fixtures.node(2, session: "w1a", parent: makeID(1)),
            Fixtures.node(3, session: "w1b", parent: makeID(1)),
            Fixtures.node(4, kind: .manager, session: "lead2"),
            Fixtures.node(5, session: "w2a", parent: makeID(4)),
        ])
    }

    private func apply(_ moves: [NavigationMove], in topology: Topology, from state: NavigationState = .init()) -> NavigationState {
        moves.reduce(state) { TopologyNavigator.apply($1, to: $0, in: topology) }
    }

    func testPeerCyclingWrapsAmongSiblings() {
        let topology = twoTeams()
        var state = apply([.select(makeID(2))], in: topology)

        state = TopologyNavigator.apply(.nextPeer, to: state, in: topology)
        XCTAssertEqual(state.selectedNodeID, makeID(3))
        state = TopologyNavigator.apply(.nextPeer, to: state, in: topology)
        XCTAssertEqual(state.selectedNodeID, makeID(2), "cycling wraps within the level")
        state = TopologyNavigator.apply(.previousPeer, to: state, in: topology)
        XCTAssertEqual(state.selectedNodeID, makeID(3))
    }

    func testRootManagersArePeersOfEachOther() {
        let topology = twoTeams()
        var state = apply([.select(makeID(1))], in: topology)
        state = TopologyNavigator.apply(.nextPeer, to: state, in: topology)
        XCTAssertEqual(state.selectedNodeID, makeID(4))
        state = TopologyNavigator.apply(.nextPeer, to: state, in: topology)
        XCTAssertEqual(state.selectedNodeID, makeID(1))
    }

    func testPeerMoveDoesNothingForAnOnlyChild() {
        let topology = twoTeams()
        var state = apply([.select(makeID(5))], in: topology)
        state = TopologyNavigator.apply(.nextPeer, to: state, in: topology)
        XCTAssertEqual(state.selectedNodeID, makeID(5))
    }

    func testUpSelectsTheManagerAndDownReturnsToTheSameChild() {
        let topology = twoTeams()
        var state = apply([.select(makeID(3))], in: topology)

        state = TopologyNavigator.apply(.parent, to: state, in: topology)
        XCTAssertEqual(state.selectedNodeID, makeID(1))
        state = TopologyNavigator.apply(.child, to: state, in: topology)
        XCTAssertEqual(state.selectedNodeID, makeID(3), "down returns to the last child that was visited")
    }

    func testDownPicksTheFirstChildWithoutAMemory() {
        let topology = twoTeams()
        var state = apply([.select(makeID(1))], in: topology)
        state = TopologyNavigator.apply(.child, to: state, in: topology)
        XCTAssertEqual(state.selectedNodeID, makeID(2))
    }

    func testUpFromARootAndDownFromALeafDoNothing() {
        let topology = twoTeams()
        let atRoot = apply([.select(makeID(1)), .parent], in: topology)
        XCTAssertEqual(atRoot.selectedNodeID, makeID(1))

        let atLeaf = apply([.select(makeID(2)), .child], in: topology)
        XCTAssertEqual(atLeaf.selectedNodeID, makeID(2))
    }

    func testDeletedSelectionFallsBackToTheFirstRoot() {
        var topology = twoTeams()
        let state = apply([.select(makeID(3))], in: topology)
        topology.remove(makeID(3))

        XCTAssertNil(TopologyNavigator.normalized(state, in: topology).selectedNodeID)
        let moved = TopologyNavigator.apply(.nextPeer, to: state, in: topology)
        XCTAssertEqual(moved.selectedNodeID, makeID(1))
    }

    func testParentAndChildDoNothingWhenTheSelectionIsGone() {
        var topology = twoTeams()
        let state = apply([.select(makeID(3))], in: topology)
        topology.remove(makeID(3))

        XCTAssertNil(TopologyNavigator.apply(.parent, to: state, in: topology).selectedNodeID)
        XCTAssertEqual(
            TopologyNavigator.apply(.child, to: state, in: topology).selectedNodeID,
            makeID(1),
            "with nothing selected, moving down starts at the first root")
    }

    func testRememberedChildIsForgottenWhenThatChildIsDeleted() {
        var topology = twoTeams()
        var state = apply([.select(makeID(3)), .parent], in: topology)
        XCTAssertEqual(state.lastVisitedChild[makeID(1)], makeID(3))

        topology.remove(makeID(3))
        state = TopologyNavigator.apply(.child, to: state, in: topology)
        XCTAssertEqual(state.selectedNodeID, makeID(2), "a deleted memory falls back to the first report")
    }

    func testRememberedChildIsForgottenWhenThatChildIsReparented() throws {
        var topology = twoTeams()
        var state = apply([.select(makeID(3)), .parent], in: topology)

        try topology.reparent(makeID(3), to: makeID(4))
        state = TopologyNavigator.apply(.child, to: state, in: topology)
        XCTAssertEqual(state.selectedNodeID, makeID(2))
    }

    func testSelectingAnAbsentNodeIsIgnored() {
        let topology = twoTeams()
        let state = apply([.select(makeID(2)), .select(makeID(999))], in: topology)
        XCTAssertEqual(state.selectedNodeID, makeID(2))
    }

    func testPeersOfANode() {
        let topology = twoTeams()
        XCTAssertEqual(TopologyNavigator.peers(of: makeID(2), in: topology).map(\.id), [makeID(2), makeID(3)])
        XCTAssertEqual(TopologyNavigator.peers(of: makeID(1), in: topology).map(\.id), [makeID(1), makeID(4)])
        XCTAssertTrue(TopologyNavigator.peers(of: makeID(999), in: topology).isEmpty)
    }
}
