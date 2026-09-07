import XCTest
@testable import MarmyCore

final class WorkspaceStoreTests: XCTestCase {

    private var directory: URL!
    private var store: WorkspaceStore!

    override func setUpWithError() throws {
        // Every test gets its own throwaway directory. Nothing here ever touches
        // the real ~/Library/Application Support.
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarmyCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = WorkspaceStore(directoryURL: directory)
    }

    override func tearDownWithError() throws {
        // Restore write permission first: one test removes it on purpose.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }

    private func sampleWorkspace(named name: String) -> Workspace {
        var workspace = Workspace.starter()
        workspace.operatorName = "Marwan"
        workspace.upsert(Fixtures.team(name: name, promptTemplateID: DefaultTemplates.ID.workerPrompt))
        return workspace
    }

    func testRoundTripsTopologiesAndTemplatesTogether() throws {
        let workspace = sampleWorkspace(named: "Mac work")
        try store.save(workspace)
        let loaded = try store.load()

        XCTAssertEqual(loaded, workspace)
        XCTAssertEqual(loaded.version, Workspace.currentVersion)
        XCTAssertEqual(loaded.topologies.count, 1)
        XCTAssertEqual(loaded.promptTemplates.count, 3)
        XCTAssertEqual(loaded.topologyTemplates.count, 2)
        XCTAssertEqual(loaded.operatorName, "Marwan")
    }

    func testEverythingSurvivesARestartIncludingNavigationRelevantStructure() throws {
        var workspace = sampleWorkspace(named: "Mac work")
        workspace.topologies[0].nodes[1].attachedSessionName = "existing_build"
        workspace.topologies[0].nodes[1].model = "some-model-the-user-typed"
        try store.save(workspace)

        let reopened = try WorkspaceStore(directoryURL: directory).load()
        let node = reopened.topologies[0].nodes[1]
        XCTAssertEqual(node.attachedSessionName, "existing_build")
        XCTAssertEqual(node.model, "some-model-the-user-typed")
        XCTAssertEqual(node.contactIDs, [Fixtures.workerBID])
        XCTAssertEqual(node.parentID, Fixtures.managerID)
    }

    func testFirstRunReturnsTheStarterWorkspaceWithoutWritingAnything() throws {
        let workspace = try store.loadOrStarter()
        XCTAssertFalse(store.fileExists, "loading must not create a file on its own")
        XCTAssertEqual(workspace.topologyTemplates.count, 2)
    }

    func testVersionIsStampedOnSave() throws {
        var workspace = Workspace.starter()
        workspace.version = 0
        try store.save(workspace)

        let raw = try String(contentsOf: store.fileURL, encoding: .utf8)
        XCTAssertTrue(raw.contains("\"version\" : \(Workspace.currentVersion)"))
    }

    func testCorruptFileIsReportedAndLeftAlone() throws {
        let garbage = "{ this is not json"
        try garbage.write(to: store.fileURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try store.load()) { error in
            guard case WorkspaceStoreError.corrupted = error else {
                return XCTFail("expected .corrupted, got \(error)")
            }
        }
        XCTAssertThrowsError(try store.loadOrStarter(), "a bad file must never be silently replaced")
        XCTAssertEqual(try String(contentsOf: store.fileURL, encoding: .utf8), garbage)
    }

    func testFileFromANewerVersionIsReportedAsSuch() throws {
        let future = """
        {"version": \(Workspace.currentVersion + 1), "topologies": [], "promptTemplates": [], \
        "topologyTemplates": [], "operatorName": ""}
        """
        try future.write(to: store.fileURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try store.load()) { error in
            guard case WorkspaceStoreError.unsupportedVersion(_, let found, let supported) = error else {
                return XCTFail("expected .unsupportedVersion, got \(error)")
            }
            XCTAssertEqual(found, Workspace.currentVersion + 1)
            XCTAssertEqual(supported, Workspace.currentVersion)
        }
    }

    func testMissingFieldsAreReportedRatherThanGuessed() throws {
        try "{}".write(to: store.fileURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.load()) { error in
            guard case WorkspaceStoreError.corrupted = error else {
                return XCTFail("expected .corrupted, got \(error)")
            }
        }
    }

    func testMissingRequiredCollectionsAreReportedEvenWithAValidVersion() throws {
        // A truncated file must not read as "you have no teams". Every one of
        // these collections has existed since v1, so an absent one is damage.
        let cases: [(String, String)] = [
            ("only a version", #"{"version": 1}"#),
            ("no topologies", #"{"version": 1, "promptTemplates": [], "topologyTemplates": []}"#),
            ("no promptTemplates", #"{"version": 1, "topologies": [], "topologyTemplates": []}"#),
            ("no topologyTemplates", #"{"version": 1, "topologies": [], "promptTemplates": []}"#),
        ]

        for (label, json) in cases {
            try json.write(to: store.fileURL, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try store.load(), label) { error in
                guard case WorkspaceStoreError.corrupted = error else {
                    return XCTFail("\(label): expected .corrupted, got \(error)")
                }
            }
            XCTAssertThrowsError(try store.loadOrStarter(), "\(label): must not fall back to a starter workspace")
            XCTAssertEqual(try String(contentsOf: store.fileURL, encoding: .utf8), json, label)
        }
    }

    func testMissingOperatorNameStillLoads() throws {
        // operatorName arrived after the collections, so its absence is fine.
        let json = #"{"version": 1, "topologies": [], "promptTemplates": [], "topologyTemplates": []}"#
        try json.write(to: store.fileURL, atomically: true, encoding: .utf8)

        let loaded = try store.load()
        XCTAssertEqual(loaded.operatorName, "")
        XCTAssertTrue(loaded.topologies.isEmpty)
    }

    func testUnknownFutureFieldsDoNotBlockLoading() throws {
        try store.save(sampleWorkspace(named: "Mac work"))
        var raw = try String(contentsOf: store.fileURL, encoding: .utf8)
        raw = raw.replacingOccurrences(
            of: "{\n  \"operatorName\"",
            with: "{\n  \"somethingFromAFutureBuild\" : true,\n  \"operatorName\"")
        try raw.write(to: store.fileURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(try store.load().topologies.count, 1)
    }

    func testPreviousContentsAreKeptAsABackup() throws {
        try store.save(sampleWorkspace(named: "First"))
        try store.save(sampleWorkspace(named: "Second"))

        XCTAssertEqual(try store.load().topologies[0].name, "Second")
        XCTAssertEqual(try store.loadBackup().topologies[0].name, "First")
    }

    func testNoBackupBeforeTheSecondSave() throws {
        try store.save(sampleWorkspace(named: "First"))
        XCTAssertFalse(store.backupExists)
        XCTAssertThrowsError(try store.loadBackup()) { error in
            guard case WorkspaceStoreError.noBackup = error else {
                return XCTFail("expected .noBackup, got \(error)")
            }
        }
    }

    func testAFailedSaveLeavesTheGoodFileInPlace() throws {
        try store.save(sampleWorkspace(named: "Good"))
        let before = try Data(contentsOf: store.fileURL)

        // Make the directory read-only so the save cannot land.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }

        XCTAssertThrowsError(try store.save(sampleWorkspace(named: "Doomed"))) { error in
            guard let storeError = error as? WorkspaceStoreError else {
                return XCTFail("expected a WorkspaceStoreError, got \(error)")
            }
            XCTAssertTrue(storeError.leftFileIntact)
        }
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
        XCTAssertEqual(try store.load().topologies[0].name, "Good")
    }

    func testSaveCreatesTheDirectoryWhenItIsMissing() throws {
        let nested = directory.appendingPathComponent("a/b/c", isDirectory: true)
        let nestedStore = WorkspaceStore(directoryURL: nested)
        try nestedStore.save(Workspace.starter())
        XCTAssertTrue(nestedStore.fileExists)
    }

    func testDefaultDirectoryIsUnderApplicationSupport() {
        let url = WorkspaceStore.defaultDirectory()
        XCTAssertEqual(url.lastPathComponent, "MarmyDesktop")
        XCTAssertTrue(url.path.contains("Application Support"))
    }
}
