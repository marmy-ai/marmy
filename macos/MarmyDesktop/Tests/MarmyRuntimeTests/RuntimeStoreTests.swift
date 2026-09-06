import XCTest
@testable import MarmyRuntime

final class RuntimeStoreTests: XCTestCase {

    private var directory: URL!
    private var store: RuntimeStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RuntimeStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = RuntimeStore(directoryURL: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }

    private func binding(nodeID: UUID = UUID(), session: String = "$1", pane: String = "%1") -> AgentBinding {
        AgentBinding(
            topologyID: UUID(), nodeID: nodeID, generation: UUID(),
            sessionName: "build", sessionID: session, paneID: pane,
            server: TmuxFixtures.identity, ownership: .launched, cli: .claude, startedAt: Date())
    }

    func testLedgerRoundTrips() throws {
        var ledger = RuntimeLedger()
        let entry = binding()
        ledger.upsert(entry)
        try store.saveLedger(ledger)

        let loaded = try store.loadLedger()
        XCTAssertEqual(loaded.bindings.count, 1)
        XCTAssertEqual(loaded.binding(nodeID: entry.nodeID)?.paneID, "%1")
        XCTAssertEqual(loaded.version, RuntimeLedger.currentVersion)
    }

    func testMissingLedgerIsSimplyEmpty() throws {
        XCTAssertTrue(try store.loadLedger().bindings.isEmpty)
    }

    func testUnreadableLedgerIsReportedNotTreatedAsEmpty() throws {
        // "I cannot read your agents" must never look like "you have none".
        try store.saveLedger(RuntimeLedger(bindings: [binding()]))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.ledgerURL.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: store.ledgerURL.path)
        }

        XCTAssertThrowsError(try store.loadLedger()) { error in
            guard case RuntimeStoreError.unreadable = error else {
                return XCTFail("expected .unreadable, got \(error)")
            }
        }
    }

    func testCorruptLedgerIsReported() throws {
        try "{ not json".write(to: store.ledgerURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.loadLedger()) { error in
            guard case RuntimeStoreError.corrupted = error else {
                return XCTFail("expected .corrupted, got \(error)")
            }
        }
    }

    func testNewerLedgerVersionIsReported() throws {
        try #"{"version": 99, "bindings": []}"#.write(to: store.ledgerURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.loadLedger()) { error in
            guard case RuntimeStoreError.unsupportedVersion = error else {
                return XCTFail("expected .unsupportedVersion, got \(error)")
            }
        }
    }

    func testForgettingANodeOnlyRemovesTheRecord() {
        var ledger = RuntimeLedger()
        let entry = binding()
        ledger.upsert(entry)
        XCTAssertNotNil(ledger.remove(nodeID: entry.nodeID))
        XCTAssertTrue(ledger.bindings.isEmpty)
        XCTAssertNil(ledger.remove(nodeID: entry.nodeID))
    }

    func testSpecFilesAreWrittenIntoALockedDownDirectory() throws {
        // A spec holds a rendered prompt, so nobody else on the machine gets to
        // read it, not even for the moment between write and chmod.
        let spec = LaunchSpec(
            executablePath: "/bin/cat", arguments: ["--", "secret prompt"],
            workingDirectory: "/tmp", topologyID: UUID(), nodeID: UUID(), generation: UUID())
        let url = try store.writeSpec(spec)

        let directoryMode = try FileManager.default.attributesOfItem(
            atPath: store.specsDirectoryURL.path)[.posixPermissions] as? NSNumber
        let fileMode = try FileManager.default.attributesOfItem(
            atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(directoryMode?.intValue, 0o700)
        XCTAssertEqual(fileMode?.intValue, 0o600)
    }

    func testSweepRemovesOnlyOldSpecs() throws {
        let old = try store.writeSpec(LaunchSpec(
            executablePath: "/bin/cat", arguments: [], workingDirectory: "/tmp",
            topologyID: UUID(), nodeID: UUID(), generation: UUID()))
        let fresh = try store.writeSpec(LaunchSpec(
            executablePath: "/bin/cat", arguments: [], workingDirectory: "/tmp",
            topologyID: UUID(), nodeID: UUID(), generation: UUID()))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: old.path)

        store.sweepStaleSpecs()
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path), "a spec still in flight is kept")
    }

    func testDataDirectoryHonorsTheEnvironmentOverride() {
        let url = RuntimeStore.defaultDirectory(environment: ["MARMY_DATA_DIR": "/tmp/marmy-smoke"])
        XCTAssertEqual(url.path, "/tmp/marmy-smoke")
        XCTAssertTrue(RuntimeStore.defaultDirectory(environment: [:]).path.contains("MarmyDesktop"))
    }
}
