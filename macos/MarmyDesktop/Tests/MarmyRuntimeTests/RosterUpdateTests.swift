import XCTest
import MarmyCore
@testable import MarmyRuntime

/// What an agent is told about its own team.
///
/// Marmy sends the whole picture rather than a list of edits, so these tests are
/// mostly about what the picture contains and when it counts as changed.
final class RosterUpdateTests: XCTestCase {

    private let managerID = UUID()
    private let workerID = UUID()
    private let otherID = UUID()
    private let terminalID = UUID()

    private func team(
        contacts: Set<UUID> = [],
        workerParent: UUID? = nil,
        includeOther: Bool = true,
        includeTerminal: Bool = false
    ) -> Topology {
        var nodes = [
            AgentNode(
                id: managerID, sessionName: "lead", displayName: "Lead", kind: .manager,
                roleTitle: "Reviews", cli: .claude, workingDirectory: "/tmp"),
            AgentNode(
                id: workerID, sessionName: "build", displayName: "Build", kind: .worker,
                roleTitle: "Implementation", cli: .codex, workingDirectory: "/tmp",
                parentID: workerParent ?? managerID, contactIDs: contacts),
        ]
        if includeOther {
            nodes.append(AgentNode(
                id: otherID, sessionName: "docs", displayName: "Docs", kind: .worker,
                roleTitle: "Docs", cli: .claude, workingDirectory: "/tmp", parentID: managerID))
        }
        if includeTerminal {
            nodes.append(AgentNode(
                id: terminalID, sessionName: "watch", displayName: "Watch", kind: .worker,
                cli: .terminal, workingDirectory: "/tmp", parentID: managerID))
        }
        return Topology(name: "Team", nodes: nodes)
    }

    private func running(_ ids: [UUID], names: [UUID: String] = [:]) -> [UUID: AgentRuntimeState] {
        Dictionary(uniqueKeysWithValues: ids.map { id in
            (id, AgentRuntimeState.running(
                paneID: "%1", sessionName: names[id] ?? "marmy-\(id.uuidString.prefix(4))",
                adopted: false))
        })
    }

    // MARK: - What it says

    func testAManagerIsToldItsWholeTeam() throws {
        let topology = team()
        let snapshot = try XCTUnwrap(RosterUpdate.snapshot(
            for: managerID, in: topology, states: running([workerID, otherID])))

        XCTAssertTrue(snapshot.message.contains("Build"))
        XCTAssertTrue(snapshot.message.contains("Docs"))
        XCTAssertTrue(snapshot.message.contains("You report to the person running Marmy"),
                      snapshot.message)
        XCTAssertFalse(snapshot.message.contains("\n"), "one line, always")
    }

    func testARemovedManagerLeavesTheHumanRatherThanYourself() throws {
        var topology = team()
        topology.remove(managerID)
        let snapshot = try XCTUnwrap(RosterUpdate.snapshot(
            for: workerID, in: topology, operatorName: "Marwan"))

        XCTAssertTrue(snapshot.message.contains("You report to Marwan, the person running Marmy"),
                      snapshot.message)
        XCTAssertFalse(snapshot.message.contains("You report to Build"))
    }

    func testTheUpdateDoesNotClaimToReplaceAnyoneInstructions() throws {
        let snapshot = try XCTUnwrap(RosterUpdate.snapshot(for: managerID, in: team()))

        XCTAssertTrue(snapshot.message.contains("your role, your instructions, and any rules you "
            + "were given about committing, pushing, or what you may change are unaffected"),
            snapshot.message)
    }

    func testARestartInTheSameSessionNameStillCountsAsNews() throws {
        // Same name, new pane: the agent you were talking to is not there.
        let before = try XCTUnwrap(RosterUpdate.snapshot(
            for: managerID, in: team(),
            states: [workerID: .running(paneID: "%2", sessionName: "build", adopted: false)]))
        let after = try XCTUnwrap(RosterUpdate.snapshot(
            for: managerID, in: team(),
            states: [workerID: .running(paneID: "%9", sessionName: "build", adopted: false)]))

        XCTAssertNotEqual(before.fingerprint, after.fingerprint)
        XCTAssertTrue(after.message.contains("pane %9"), after.message)
    }

    func testTheAddressIsWhereTheAgentActuallyIs() throws {
        // Adopted, or renamed: the planned session name is not where it lives.
        let topology = team()
        let snapshot = try XCTUnwrap(RosterUpdate.snapshot(
            for: managerID, in: topology,
            states: running([workerID, otherID], names: [workerID: "someone-elses-session"])))

        XCTAssertTrue(snapshot.message.contains("someone-elses-session"))
        XCTAssertFalse(snapshot.message.contains("(build,"), "not the address the plan wanted")
    }

    func testAnAgentThatIsNotUpYetIsDescribedAsSuch() throws {
        let snapshot = try XCTUnwrap(RosterUpdate.snapshot(
            for: managerID, in: team(), states: running([otherID])))

        XCTAssertTrue(snapshot.message.contains("Build (build, Implementation, not started yet)"))
    }

    func testAManualTerminalIsListedAsOneNobodyMessages() throws {
        let snapshot = try XCTUnwrap(RosterUpdate.snapshot(
            for: managerID, in: team(includeTerminal: true), states: running([terminalID])))

        XCTAssertTrue(snapshot.message.contains("Watch"))
        XCTAssertTrue(snapshot.message.contains("do not message it"))
    }

    func testATerminalIsNeverToldAnything() {
        XCTAssertNil(RosterUpdate.snapshot(
            for: terminalID, in: team(includeTerminal: true)),
            "prose typed into a shell is a command")
    }

    func testContactsAreListedBothWaysRound() throws {
        let topology = team(contacts: [otherID])
        let toBuild = try XCTUnwrap(RosterUpdate.snapshot(for: workerID, in: topology))
        let toDocs = try XCTUnwrap(RosterUpdate.snapshot(for: otherID, in: topology))

        XCTAssertTrue(toBuild.message.contains("You may also talk to: Docs"))
        XCTAssertTrue(toDocs.message.contains("These may contact you: Build"),
                      "being messaged by an agent you were never told about is confusing")
    }

    // MARK: - When it counts as changed

    func testTheSameTeamProducesTheSameFingerprint() throws {
        let first = try XCTUnwrap(RosterUpdate.snapshot(
            for: managerID, in: team(), states: running([workerID, otherID])))
        let second = try XCTUnwrap(RosterUpdate.snapshot(
            for: managerID, in: team(), states: running([workerID, otherID])))

        XCTAssertEqual(first.fingerprint, second.fingerprint)
    }

    func testAddingRemovingReparentingAndRenamingAllChangeIt() throws {
        let base = try XCTUnwrap(RosterUpdate.snapshot(for: managerID, in: team()))

        var added = team()
        added.upsert(AgentNode(
            sessionName: "extra", displayName: "Extra", kind: .worker,
            workingDirectory: "/tmp", parentID: managerID))
        XCTAssertNotEqual(try XCTUnwrap(RosterUpdate.snapshot(for: managerID, in: added)).fingerprint,
                          base.fingerprint, "a new report")

        var removed = team()
        removed.remove(otherID)
        XCTAssertNotEqual(try XCTUnwrap(RosterUpdate.snapshot(for: managerID, in: removed)).fingerprint,
                          base.fingerprint, "one gone")

        var reparented = team()
        var worker = try XCTUnwrap(reparented.node(workerID))
        worker.parentID = otherID
        reparented.upsert(worker)
        XCTAssertNotEqual(
            try XCTUnwrap(RosterUpdate.snapshot(for: managerID, in: reparented)).fingerprint,
            base.fingerprint, "moved under someone else")

        var renamed = team()
        var docs = try XCTUnwrap(renamed.node(otherID))
        docs.displayName = "Documentation"
        renamed.upsert(docs)
        XCTAssertNotEqual(try XCTUnwrap(RosterUpdate.snapshot(for: managerID, in: renamed)).fingerprint,
                          base.fingerprint, "called something else now")
    }

    func testComingUpAndDyingBothChangeIt() throws {
        let down = try XCTUnwrap(RosterUpdate.snapshot(for: managerID, in: team()))
        let up = try XCTUnwrap(RosterUpdate.snapshot(
            for: managerID, in: team(), states: running([workerID, otherID])))
        XCTAssertNotEqual(down.fingerprint, up.fingerprint)

        // And back down again: a death is as much news as a start.
        let againDown = try XCTUnwrap(RosterUpdate.snapshot(for: managerID, in: team()))
        XCTAssertEqual(againDown.fingerprint, down.fingerprint)
        XCTAssertNotEqual(againDown.fingerprint, up.fingerprint)
    }

    func testTheSameNameOnANewSessionChangesIt() throws {
        let first = try XCTUnwrap(RosterUpdate.snapshot(
            for: managerID, in: team(), states: running([workerID], names: [workerID: "build"])))
        let moved = try XCTUnwrap(RosterUpdate.snapshot(
            for: managerID, in: team(), states: running([workerID], names: [workerID: "build-2"])))

        XCTAssertNotEqual(first.fingerprint, moved.fingerprint)
    }

    func testAddThenRemoveIsBackWhereItStarted() throws {
        // Two edits that cancel out say nothing new — which is exactly why the
        // whole picture is sent rather than a list of edits.
        let before = try XCTUnwrap(RosterUpdate.snapshot(for: managerID, in: team()))
        var changed = team()
        let extra = AgentNode(
            sessionName: "extra", displayName: "Extra", kind: .worker,
            workingDirectory: "/tmp", parentID: managerID)
        changed.upsert(extra)
        changed.remove(extra.id)

        XCTAssertEqual(try XCTUnwrap(RosterUpdate.snapshot(for: managerID, in: changed)).fingerprint,
                       before.fingerprint)
    }

    func testAChangeElsewhereOnTheTeamDoesNotDisturbSomeoneUninvolved() throws {
        // Docs has no relationship to a second manager's people.
        let base = try XCTUnwrap(RosterUpdate.snapshot(for: otherID, in: team()))
        var changed = team()
        changed.upsert(AgentNode(
            sessionName: "solo", displayName: "Solo", kind: .manager, workingDirectory: "/tmp"))

        XCTAssertEqual(try XCTUnwrap(RosterUpdate.snapshot(for: otherID, in: changed)).fingerprint,
                       base.fingerprint)
    }
}
