import XCTest
@testable import MarmyCore

final class TopologyTemplateTests: XCTestCase {

    func testAllocatorAvoidsNamesAlreadyInUse() {
        var allocator = SessionNameAllocator(existingNames: ["lead", "build"])
        XCTAssertEqual(allocator.allocate("lead"), "lead-2")
        XCTAssertEqual(allocator.allocate("lead"), "lead-3")
        XCTAssertEqual(allocator.allocate("verify"), "verify")
    }

    func testAllocatorSanitizesNames() {
        var allocator = SessionNameAllocator()
        XCTAssertEqual(allocator.allocate("My Team Lead"), "My-Team-Lead")
        XCTAssertEqual(allocator.allocate("My Team Lead"), "My-Team-Lead-2")
    }

    func testAllocatorTerminatesAtTheNameLengthLimit() {
        // The suffix has to survive truncation, or every attempt produces the
        // same already-taken name and the allocator spins forever.
        let base = String(repeating: "a", count: TmuxName.maxLength)
        var allocator = SessionNameAllocator()
        var produced: [String] = []
        for _ in 0..<12 {
            produced.append(allocator.allocate(base))
        }

        XCTAssertEqual(Set(produced).count, produced.count, "every allocation must be distinct")
        for name in produced {
            XCTAssertTrue(TmuxName.isValid(name), "\(name) is not a usable tmux name")
            XCTAssertLessThanOrEqual(name.count, TmuxName.maxLength)
        }
        XCTAssertEqual(produced[0], base)
        XCTAssertTrue(produced[1].hasSuffix("-2"))
    }

    func testAllocatorHandlesLongNamesPastTenCollisions() {
        let base = String(repeating: "b", count: TmuxName.maxLength - 1)
        var allocator = SessionNameAllocator()
        var produced: Set<String> = []
        for _ in 0..<25 {
            let name = allocator.allocate(base)
            XCTAssertTrue(TmuxName.isValid(name))
            XCTAssertTrue(produced.insert(name).inserted)
        }
    }

    func testInstantiationRemapsIdentitiesAndKeepsEdgeStructure() {
        let template = DefaultTemplates.starterTeam(workingDirectory: "/tmp/marmy-tests")
        let ids = IDSequence()
        let live = template.instantiate(name: "Mac work", existingSessionNames: [], makeID: ids.callAsFunction)

        XCTAssertEqual(live.name, "Mac work")
        XCTAssertNotEqual(live.id, template.prototype.id)
        XCTAssertEqual(live.nodes.count, 3)

        for (fresh, original) in zip(live.nodes, template.prototype.nodes) {
            XCTAssertNotEqual(fresh.id, original.id)
            XCTAssertEqual(fresh.displayName, original.displayName)
            XCTAssertEqual(fresh.kind, original.kind)
            XCTAssertEqual(fresh.promptTemplateID, original.promptTemplateID)
            XCTAssertEqual(fresh.workingDirectory, original.workingDirectory)
        }

        // Edge structure survives the remap.
        XCTAssertNil(live.nodes[0].parentID)
        XCTAssertEqual(live.nodes[1].parentID, live.nodes[0].id)
        XCTAssertEqual(live.nodes[2].parentID, live.nodes[0].id)
        XCTAssertEqual(live.nodes[1].contactIDs, [live.nodes[2].id])
        XCTAssertEqual(live.nodes[2].contactIDs, [live.nodes[1].id])
        XCTAssertTrue(TopologyValidator.validate(live, promptTemplates: DefaultTemplates.promptTemplates())
            .errors.isEmpty)
    }

    func testInstantiationAvoidsSessionNamesAlreadyClaimed() {
        let template = DefaultTemplates.starterTeam(workingDirectory: "/tmp/marmy-tests")
        let live = template.instantiate(existingSessionNames: ["lead", "build"])
        XCTAssertEqual(live.nodes.map(\.sessionName), ["lead-2", "build-2", "verify"])
    }

    func testInstantiationDoesNotCarryAnAttachedSession() {
        var prototype = Fixtures.team()
        prototype.nodes[0].attachedSessionName = "already-running"
        let template = TopologyTemplate(capturing: prototype)

        XCTAssertNil(template.prototype.nodes[0].attachedSessionName)
        XCTAssertNil(template.instantiate().nodes[0].attachedSessionName)
    }

    func testTwoInstantiationsNeverCollide() {
        var workspace = Workspace.starter()
        let first = workspace.instantiateTopologyTemplate(DefaultTemplates.ID.starterTeam, name: "One")!
        let second = workspace.instantiateTopologyTemplate(DefaultTemplates.ID.starterTeam, name: "Two")!

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertTrue(Set(first.nodes.map(\.id)).isDisjoint(with: Set(second.nodes.map(\.id))))
        XCTAssertTrue(Set(first.nodes.map(\.sessionName)).isDisjoint(with: Set(second.nodes.map(\.sessionName))))
        XCTAssertEqual(workspace.topologies.count, 2)
    }

    func testInstantiatingAnUnknownTemplateChangesNothing() {
        var workspace = Workspace.starter()
        XCTAssertNil(workspace.instantiateTopologyTemplate(makeID(42)))
        XCTAssertTrue(workspace.topologies.isEmpty)
    }

    func testCapturingATopologyKeepsItsShape() {
        let team = Fixtures.team(name: "Captured")
        let template = TopologyTemplate(capturing: team, name: "Saved shape")

        XCTAssertEqual(template.name, "Saved shape")
        XCTAssertEqual(template.prototype.nodes.map(\.sessionName), ["lead", "build", "verify"])
        XCTAssertFalse(template.isBuiltIn)
    }

    func testPromptTemplateDuplicationTakesAFreshIdentity() {
        let original = DefaultTemplates.workerPrompt()
        let copy = original.duplicated()

        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.body, original.body)
        XCTAssertFalse(copy.isBuiltIn)
        XCTAssertEqual(copy.name, "Implementation worker copy")
    }

    func testRemovingAPromptTemplateClearsItEverywhere() {
        var workspace = Workspace.starter()
        let live = workspace.instantiateTopologyTemplate(DefaultTemplates.ID.starterTeam)!
        XCTAssertEqual(live.nodes[1].promptTemplateID, DefaultTemplates.ID.workerPrompt)

        XCTAssertTrue(workspace.removePromptTemplate(DefaultTemplates.ID.workerPrompt))
        XCTAssertTrue(workspace.topologies[0].nodes.allSatisfy { $0.promptTemplateID != DefaultTemplates.ID.workerPrompt })
        XCTAssertTrue(workspace.topologyTemplates.allSatisfy { template in
            template.prototype.nodes.allSatisfy { $0.promptTemplateID != DefaultTemplates.ID.workerPrompt }
        })
        XCTAssertTrue(TopologyValidator.validate(
            workspace.topologies[0], promptTemplates: workspace.promptTemplates).errors.isEmpty)
    }

    func testClaimedSessionNamesIncludeAttachedSessions() {
        var workspace = Workspace.starter()
        var team = Fixtures.team()
        team.nodes[0].attachedSessionName = "existing_lead"
        workspace.upsert(team)

        XCTAssertEqual(workspace.claimedSessionNames, ["lead", "existing_lead", "build", "verify"])
    }
}
