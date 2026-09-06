import XCTest
@testable import MarmyCore

final class TopologyStructureTests: XCTestCase {

    func testChildrenAndRootsFollowNodeOrder() {
        let team = Fixtures.team()
        XCTAssertEqual(team.roots.map(\.id), [Fixtures.managerID])
        XCTAssertEqual(team.children(of: Fixtures.managerID).map(\.sessionName), ["build", "verify"])
    }

    func testRemoveLiftsChildrenToTheManagerAbove() throws {
        var team = Fixtures.team()
        let lead = Fixtures.node(4, kind: .manager, session: "director")
        team.upsert(lead)
        try team.reparent(Fixtures.managerID, to: lead.id)

        XCTAssertTrue(team.remove(Fixtures.managerID))
        XCTAssertEqual(team.node(Fixtures.workerAID)?.parentID, lead.id)
        XCTAssertEqual(team.node(Fixtures.workerBID)?.parentID, lead.id)
    }

    func testRemoveMakesOrphansRootsAndDropsContactReferences() {
        var team = Fixtures.team()
        XCTAssertTrue(team.remove(Fixtures.managerID))
        XCTAssertEqual(team.roots.count, 2)

        XCTAssertTrue(team.remove(Fixtures.workerBID))
        XCTAssertEqual(team.node(Fixtures.workerAID)?.contactIDs, [])
        XCTAssertTrue(TopologyValidator.validate(team).errors.isEmpty)
    }

    func testReparentRefusesSelfParentingCyclesAndWorkerParents() throws {
        var team = Fixtures.team()
        let subManager = Fixtures.node(5, kind: .manager, session: "sub", parent: Fixtures.managerID)
        team.upsert(subManager)

        XCTAssertThrowsError(try team.reparent(Fixtures.managerID, to: Fixtures.managerID)) { error in
            XCTAssertEqual(error as? TopologyMutationError, .selfParent(Fixtures.managerID))
        }
        XCTAssertThrowsError(try team.reparent(Fixtures.managerID, to: subManager.id)) { error in
            XCTAssertEqual(
                error as? TopologyMutationError,
                .cycle(childID: Fixtures.managerID, parentID: subManager.id))
        }
        XCTAssertThrowsError(try team.reparent(subManager.id, to: Fixtures.workerAID)) { error in
            XCTAssertEqual(error as? TopologyMutationError, .parentIsNotManager(parentID: Fixtures.workerAID))
        }
        XCTAssertFalse(team.canReparent(Fixtures.managerID, to: subManager.id))
        XCTAssertTrue(team.canReparent(Fixtures.workerAID, to: subManager.id))
    }

    func testReparentDetectsDeepCycles() throws {
        var team = Topology(name: "Deep", nodes: [
            Fixtures.node(1, kind: .manager, session: "a"),
            Fixtures.node(2, kind: .manager, session: "b", parent: makeID(1)),
            Fixtures.node(3, kind: .manager, session: "c", parent: makeID(2)),
            Fixtures.node(4, kind: .manager, session: "d", parent: makeID(3)),
        ])
        XCTAssertThrowsError(try team.reparent(makeID(1), to: makeID(4)))
        XCTAssertNil(team.node(makeID(1))?.parentID, "a failed reparent must not change anything")
    }

    func testAncestorsAndDescendantsSurviveACorruptCycle() {
        // Two nodes pointing at each other can only come from a corrupt file,
        // but the traversal helpers still have to terminate.
        var a = Fixtures.node(1, kind: .manager, session: "a")
        var b = Fixtures.node(2, kind: .manager, session: "b")
        a.parentID = b.id
        b.parentID = a.id
        let team = Topology(name: "Loop", nodes: [a, b])

        XCTAssertEqual(team.ancestors(of: a.id).map(\.id), [b.id], "the walk stops before revisiting the start")
        XCTAssertEqual(team.descendants(of: a.id).map(\.id), [b.id])
    }

    func testPruneDanglingReferences() {
        var team = Fixtures.team()
        team.nodes[1].parentID = makeID(999)
        team.nodes[1].contactIDs = [makeID(998), Fixtures.workerBID, Fixtures.workerAID]
        team.pruneDanglingReferences()

        XCTAssertNil(team.nodes[1].parentID)
        XCTAssertEqual(team.nodes[1].contactIDs, [Fixtures.workerBID])
    }

    func testLinkAndUnlinkContactsAreMutual() {
        var team = Fixtures.team()
        team.linkContacts(Fixtures.managerID, Fixtures.workerAID)
        XCTAssertTrue(team.node(Fixtures.managerID)!.contactIDs.contains(Fixtures.workerAID))
        XCTAssertTrue(team.node(Fixtures.workerAID)!.contactIDs.contains(Fixtures.managerID))

        team.unlinkContacts(Fixtures.managerID, Fixtures.workerAID)
        XCTAssertFalse(team.node(Fixtures.managerID)!.contactIDs.contains(Fixtures.workerAID))
        XCTAssertFalse(team.node(Fixtures.workerAID)!.contactIDs.contains(Fixtures.managerID))
    }
}
