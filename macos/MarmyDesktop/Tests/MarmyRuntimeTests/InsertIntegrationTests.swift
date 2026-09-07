import XCTest
import MarmyCore
@testable import MarmyRuntime

/// Putting text into a prompt without running it, against a real shell.
///
/// Opt in with `MARMY_RUN_TMUX_TESTS=1`. Private socket, `-f /dev/null`, and the
/// only program started is `/bin/sh` — no agent CLI, no model.
final class InsertIntegrationTests: XCTestCase {

    private var root: URL!
    private var socketName: String!
    private var tmux: TmuxClient!
    private var runtime: AgentRuntime!
    private var started: TmuxStartedSession!
    private var server: TmuxServerIdentity!

    override func setUp() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MARMY_RUN_TMUX_TESTS"] == "1",
            "set MARMY_RUN_TMUX_TESTS=1 to run the tmux integration tests")
        guard let tmuxPath = ExecutableLocator().locate("tmux") else { throw XCTSkip("tmux is missing") }

        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarmyInsertTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        socketName = "marmy-insert-\(UUID().uuidString.prefix(8).lowercased())"

        tmux = TmuxClient(
            executablePath: tmuxPath,
            server: .named(socketName, configFile: "/dev/null"),
            runner: SystemCommandRunner())
        // A plain interactive shell: it does not turn bracketed paste on, which
        // is exactly the case a pasted newline would run.
        started = try await tmux.newSession(
            name: "shell", directory: root.path, executable: "/bin/sh", arguments: ["-i"])
        server = try await tmux.serverIdentity()
        runtime = try AgentRuntime(
            tmux: tmux, store: RuntimeStore(directoryURL: root.appendingPathComponent("runtime")))
        try await Task.sleep(for: .seconds(1))
    }

    override func tearDown() async throws {
        if let tmux { _ = try? await tmux.run(["kill-server"]) }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private var target: AgentRuntime.DeliveryTarget {
        AgentRuntime.DeliveryTarget(
            sessionID: started.sessionID, paneID: started.paneID, server: server)
    }

    private func pane() async throws -> String {
        try await tmux.capturePane(started.paneID, lines: 200, joinWrapped: true)
    }

    func testASingleLineIsPutInThePromptAndNotRun() async throws {
        let marker = "marmy-not-run-\(UUID().uuidString.prefix(6))"
        try await runtime.paste("echo \(marker)", toSessionID: started.sessionID, expecting: target)
        try await Task.sleep(for: .seconds(1))

        let contents = try await pane()
        XCTAssertTrue(contents.contains("echo \(marker)"), "the text is sitting in the prompt")
        // If it had run, the marker would appear a second time as output.
        let occurrences = contents.components(separatedBy: marker).count - 1
        XCTAssertEqual(occurrences, 1, "it was typed, not executed:\n\(contents)")
    }

    func testMultipleLinesAreRefusedAndNothingReachesTheShell() async throws {
        let before = try await pane()
        let marker = "marmy-refused-\(UUID().uuidString.prefix(6))"

        do {
            try await runtime.paste(
                "echo \(marker)\necho second line",
                toSessionID: started.sessionID, expecting: target)
            XCTFail("a multi-line automatic insert must be refused")
        } catch let error as RuntimeError {
            guard case .unsafeToInsert(let reason) = error else {
                return XCTFail("expected .unsafeToInsert, got \(error)")
            }
            XCTAssertTrue(reason.contains("kept"), "and the words are kept: \(reason)")
        }

        try await Task.sleep(for: .seconds(0.6))
        let after = try await pane()
        XCTAssertFalse(after.contains(marker), "nothing was typed")
        XCTAssertEqual(after, before, "and the shell is exactly where it was")
    }

    func testAPastedNewlineWouldHaveRunTheCommand() async throws {
        // The reason the refusal above exists, written down. Sending the same
        // text through the submit path — which is a deliberate act — runs it.
        let marker = "marmy-would-run-\(UUID().uuidString.prefix(6))"
        try await runtime.send("echo \(marker)", toSessionID: started.sessionID)
        try await Task.sleep(for: .seconds(1))

        let contents = try await pane()
        let occurrences = contents.components(separatedBy: marker).count - 1
        XCTAssertGreaterThanOrEqual(occurrences, 2, "the command echoed and then ran:\n\(contents)")
    }

    func testControlCharactersAreRefused() async throws {
        do {
            try await runtime.paste(
                "harmless\u{1B}[201~ then keystrokes",
                toSessionID: started.sessionID, expecting: target)
            XCTFail("an escape sequence must be refused")
        } catch let error as RuntimeError {
            guard case .unsafeToInsert = error else {
                return XCTFail("expected .unsafeToInsert, got \(error)")
            }
        }
    }

    func testAPasteForAPaneThatHasMovedOnIsRefused() async throws {
        let stale = AgentRuntime.DeliveryTarget(
            sessionID: started.sessionID, paneID: "%99", server: server)
        do {
            try await runtime.paste("anything", toSessionID: started.sessionID, expecting: stale)
            XCTFail("a paste for a pane that is not there must be refused")
        } catch let error as RuntimeError {
            guard case .identityMismatch = error else {
                return XCTFail("expected .identityMismatch, got \(error)")
            }
        }
    }

    func testWhatWasAlreadyTypedIsNotClearedByAPaste() async throws {
        // The user is halfway through a line; an insert has to sit alongside it.
        _ = try await tmux.run(["send-keys", "-t", started.paneID, "-l", "user typed "])
        try await Task.sleep(for: .seconds(0.5))
        try await runtime.paste("and dictated", toSessionID: started.sessionID, expecting: target)
        try await Task.sleep(for: .seconds(0.8))

        let contents = try await pane()
        XCTAssertTrue(contents.contains("user typed and dictated"), contents)
    }
}
