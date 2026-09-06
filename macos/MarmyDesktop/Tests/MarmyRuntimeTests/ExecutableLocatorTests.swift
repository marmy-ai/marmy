import XCTest
@testable import MarmyRuntime

final class ExecutableLocatorTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ name: String, executable: Bool) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
        return url
    }

    func testFindsAnExecutableOnTheSearchPath() throws {
        let url = try write("claude", executable: true)
        let locator = ExecutableLocator(searchDirectories: [directory.path])
        XCTAssertEqual(locator.locate("claude"), url.path)
    }

    func testIgnoresNonExecutableFilesAndDirectories() throws {
        _ = try write("codex", executable: false)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("tmux"), withIntermediateDirectories: true)
        let locator = ExecutableLocator(searchDirectories: [directory.path])

        XCTAssertNil(locator.locate("codex"))
        XCTAssertNil(locator.locate("tmux"))
    }

    func testSearchesCommonInstallDirectoriesBeyondPATH() {
        // A GUI app inherits a thin PATH, so Homebrew and ~/.local/bin matter.
        let locator = ExecutableLocator(environment: ["PATH": "/nonexistent"])
        XCTAssertTrue(locator.searchDirectories.contains("/opt/homebrew/bin"))
        XCTAssertTrue(locator.searchDirectories.contains("/usr/bin"))
        XCTAssertTrue(locator.searchDirectories.contains(
            NSString(string: "~/.local/bin").expandingTildeInPath))
    }

    func testDuplicateDirectoriesAreVisitedOnce() {
        let locator = ExecutableLocator(environment: ["PATH": "/usr/bin:/usr/bin:/bin"])
        XCTAssertEqual(locator.searchDirectories.filter { $0 == "/usr/bin" }.count, 1)
    }

    func testMissingToolNamesItselfAndWhereWeLooked() {
        let locator = ExecutableLocator(searchDirectories: [directory.path])
        XCTAssertThrowsError(try locator.locateOrThrow("claude")) { error in
            let text = "\(error)"
            XCTAssertTrue(text.contains("claude"))
            XCTAssertTrue(text.contains("PATH"))
            XCTAssertTrue(text.contains(self.directory.path))
        }
    }

    func testExplicitPathIsCheckedNotSearched() throws {
        let url = try write("mytool", executable: true)
        let locator = ExecutableLocator(searchDirectories: [])
        XCTAssertEqual(locator.locate(url.path), url.path)

        let plain = try write("plain", executable: false)
        XCTAssertThrowsError(try locator.locateOrThrow(plain.path)) { error in
            XCTAssertEqual(error as? ExecutableLookupError, .notExecutable(path: plain.path))
        }
    }

    func testLaunchPATHIsWhatWeSearched() {
        let locator = ExecutableLocator(searchDirectories: ["/opt/homebrew/bin", "/usr/bin"])
        XCTAssertEqual(locator.launchPATH, "/opt/homebrew/bin:/usr/bin")
    }
}
