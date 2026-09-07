import XCTest
import MarmyCore
@testable import MarmyRuntime

/// The record of everything Marmy has said to an agent.
final class MessageJournalTests: XCTestCase {

    private var root: URL!
    private var journal: MessageJournal!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarmyJournalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        journal = MessageJournal(directoryURL: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }

    private func entry(_ payload: String, status: JournalEntry.Status = .prepared) -> JournalEntry {
        JournalEntry(
            kind: .rosterUpdate, status: status, sessionName: "lead", sessionID: "$1",
            paneID: "%1", payload: payload)
    }

    func testAnEntrySurvivesBeingReopened() async throws {
        _ = try await journal.record(entry("the team as it stands"))

        let reopened = MessageJournal(directoryURL: root)
        let all = try await reopened.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.payload, "the team as it stands")
    }

    func testHistoryIsNeverTrimmed() async throws {
        for index in 0..<400 {
            _ = try await journal.record(entry("message \(index)"))
        }
        let all = try await journal.all()

        XCTAssertEqual(all.count, 400, "what an agent was told is the point of this file")
        XCTAssertEqual(all.first?.payload, "message 0")
    }

    func testAFailedWriteLeavesNothingClaimed() async throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)

        await XCTAssertThrowsErrorAsync(try await journal.record(entry("never stored")))

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let all = try await journal.all()
        XCTAssertTrue(all.isEmpty, "in memory as on disk: it was not recorded")
    }

    func testAFailedStatusWriteLeavesTheOldStatusStanding() async throws {
        let recorded = try await journal.record(entry("sent once"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)

        await XCTAssertThrowsErrorAsync(
            try await journal.update(recorded.id, status: .submitted))

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let stored = try await journal.entry(id: recorded.id)
        XCTAssertEqual(stored?.status, .prepared, "the app must not show a status the disk denies")
    }

    func testAnInterruptedSendBecomesUncertainNotUntried() async throws {
        let caught = try await journal.record(entry("in flight", status: .sending))
        let untried = try await journal.record(entry("never started"))

        let reopened = MessageJournal(directoryURL: root)
        _ = try await reopened.reconcileAfterRestart()

        let stored = try await reopened.entry(id: caught.id)
        XCTAssertEqual(stored?.status, .uncertain)
        let untriedStored = try await reopened.entry(id: untried.id)
        XCTAssertEqual(untriedStored?.status, .prepared)
        XCTAssertTrue(stored?.detail?.contains("not known") == true)
    }

    func testPendingIsOnlyWhatWasNeverAttempted() async throws {
        _ = try await journal.record(entry("waiting"))
        _ = try await journal.record(entry("in flight", status: .sending))
        _ = try await journal.record(entry("gone out", status: .submitted))

        let pending = try await journal.pending()
        XCTAssertEqual(pending.map(\.payload), ["waiting"])
    }

    func testTheFileIsReadableOnlyByItsOwner() async throws {
        _ = try await journal.record(entry("private"))

        let attributes = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent(MessageJournal.fileName).path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, 0o600)
    }

    func testAnEntryKnowsWhichTerminalItWasRecordedFor() throws {
        let server = TmuxServerIdentity(pid: 42, socketPath: "/tmp/s", startTime: 1700)
        let generation = UUID()
        let recorded = JournalEntry(
            kind: .rosterUpdate, sessionName: "lead", sessionID: "$1", paneID: "%1",
            server: server, generation: generation, payload: "hello")

        XCTAssertTrue(recorded.matches(AgentRuntime.DeliveryTarget(
            sessionID: "$1", paneID: "%1", server: server, generation: generation)))
        XCTAssertFalse(recorded.matches(AgentRuntime.DeliveryTarget(
            sessionID: "$1", paneID: "%1", server: server, generation: UUID())),
            "a relaunched agent is a different recipient")
        XCTAssertFalse(recorded.matches(AgentRuntime.DeliveryTarget(
            sessionID: "$1", paneID: "%1",
            server: TmuxServerIdentity(pid: 99, socketPath: "/tmp/s", startTime: 1800),
            generation: generation)),
            "session ids start over on a new server")
    }
}

func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: String = "expected an error",
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail(message, file: file, line: line)
    } catch {}
}
