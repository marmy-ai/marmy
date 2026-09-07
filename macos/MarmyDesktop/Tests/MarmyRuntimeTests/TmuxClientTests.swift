import XCTest
@testable import MarmyRuntime

final class TmuxClientTests: XCTestCase {

    private func client(_ runner: FakeCommandRunner, server: TmuxServerAddress = .userDefault) -> TmuxClient {
        TmuxClient(executablePath: "/opt/homebrew/bin/tmux", server: server, runner: runner)
    }

    func testSocketArgumentsComeFirst() async throws {
        let runner = FakeCommandRunner()
        runner.stub("list-sessions", TmuxFixtures.sessions([]))
        _ = try await client(runner, server: .named("marmy-test", configFile: "/dev/null")).listSessions()

        let arguments = runner.calls[0].arguments
        XCTAssertEqual(Array(arguments.prefix(5)), ["-L", "marmy-test", "-f", "/dev/null", "list-sessions"])
    }

    func testNoServerReadsAsEmptyNotAnError() async throws {
        let runner = FakeCommandRunner()
        runner.stub("list-sessions", TmuxFixtures.noServer)
        runner.stub("list-panes", TmuxFixtures.noServer)
        runner.stub("display-message", TmuxFixtures.noServer)
        let tmux = client(runner)

        let sessions = try await tmux.listSessions()
        let panes = try await tmux.listPanes()
        let identity = try await tmux.serverIdentity()
        XCTAssertTrue(sessions.isEmpty)
        XCTAssertTrue(panes.isEmpty)
        XCTAssertNil(identity)
    }

    func testNoServerRunningMessageIsAlsoEmpty() async throws {
        let runner = FakeCommandRunner()
        runner.stub("list-sessions", CommandResult(
            exitCode: 1, standardError: "no server running on /private/tmp/tmux-501/default"))
        let sessions = try await client(runner).listSessions()
        XCTAssertTrue(sessions.isEmpty)
    }

    func testPermissionErrorIsSurfacedNotSwallowed() async throws {
        // "I cannot open the socket" is not "you have no sessions".
        let runner = FakeCommandRunner()
        runner.stub("list-sessions", TmuxFixtures.permissionDenied)
        do {
            _ = try await client(runner).listSessions()
            XCTFail("expected an error")
        } catch let error as TmuxError {
            guard case .commandFailed(_, let detail) = error else {
                return XCTFail("expected .commandFailed, got \(error)")
            }
            XCTAssertTrue(detail.contains("Permission denied"))
        }
    }

    func testOtherFailuresAreSurfaced() async throws {
        let runner = FakeCommandRunner()
        runner.stub("list-panes", CommandResult(exitCode: 1, standardError: "server exited unexpectedly"))
        do {
            _ = try await client(runner).listPanes()
            XCTFail("expected an error")
        } catch let error as TmuxError {
            XCTAssertTrue("\(error)".contains("server exited unexpectedly"))
        }
    }

    func testParsesSessionsAndPanes() async throws {
        let runner = FakeCommandRunner()
        runner.stub("list-sessions", TmuxFixtures.sessions([(id: "$1", name: "lead"), (id: "$2", name: "build")]))
        runner.stub("list-panes", TmuxFixtures.panes([(pane: "%3", session: "$1", name: "lead")]))
        let tmux = client(runner)

        let sessions = try await tmux.listSessions()
        XCTAssertEqual(sessions.map(\.name), ["lead", "build"])
        XCTAssertEqual(sessions[0].id, "$1")

        let panes = try await tmux.listPanes()
        XCTAssertEqual(panes[0].id, "%3")
        XCTAssertEqual(panes[0].sessionID, "$1")
        XCTAssertTrue(panes[0].isActive)
    }

    func testMalformedListingThrows() async throws {
        let runner = FakeCommandRunner()
        runner.stub("list-sessions", CommandResult(exitCode: 0, standardOutput: "$1|lead|1700|0|1\n"))
        do {
            _ = try await client(runner).listSessions()
            XCTFail("expected an error")
        } catch let error as TmuxError {
            guard case .unexpectedOutput = error else { return XCTFail("expected .unexpectedOutput, got \(error)") }
        }
    }

    func testNewSessionPassesArgumentsDirectly() async throws {
        let runner = FakeCommandRunner()
        runner.stub("new-session", TmuxFixtures.started(session: "$7", name: "build", pane: "%9"))

        let started = try await client(runner).newSession(
            name: "build", directory: "/tmp/work",
            executable: "/apps/marmy-agent-launch", arguments: ["--run-agent", "/data/spec.json"])

        XCTAssertEqual(started.sessionID, "$7")
        XCTAssertEqual(started.paneID, "%9")
        let arguments = runner.calls(of: "new-session")[0].arguments
        XCTAssertEqual(arguments.prefix(6), ["new-session", "-d", "-s", "build", "-c", "/tmp/work"])
        XCTAssertEqual(arguments.suffix(3), ["/apps/marmy-agent-launch", "--run-agent", "/data/spec.json"])
    }

    func testMessageTextTravelsThroughStdinOnly() async throws {
        let runner = FakeCommandRunner()
        let text = "line one; echo pwned\n`backtick` $HOME \u{22}quoted\u{22}\n-leading dash\nünicode ✅"
        try await client(runner).loadBuffer(name: "marmy-1", text: text)

        let call = runner.calls(of: "load-buffer")[0]
        XCTAssertEqual(call.arguments, ["load-buffer", "-b", "marmy-1", "-"])
        XCTAssertEqual(call.standardInput, Data(text.utf8))
        XCTAssertFalse(call.arguments.contains { $0.contains("echo pwned") },
                       "message text must never reach an argument vector")
    }

    func testTmuxCommandsDropInheritedTmuxVariables() async throws {
        // A stale TMUX from the pane Marmy was launched from would point tmux at
        // the wrong server, so the controller's own calls must not carry it.
        let capturing = CapturingRunner()
        let tmux = TmuxClient(executablePath: "/opt/homebrew/bin/tmux", runner: capturing)
        _ = try await tmux.listSessions()

        let environment = try XCTUnwrap(capturing.invocations.first?.environment)
        XCTAssertNil(environment["TMUX"])
        XCTAssertNil(environment["TMUX_PANE"])
        XCTAssertNotNil(environment["PATH"], "the rest of the environment is preserved")
    }
}

/// Records the full invocation, environment included.
private final class CapturingRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _invocations: [CommandInvocation] = []

    var invocations: [CommandInvocation] {
        lock.lock(); defer { lock.unlock() }
        return _invocations
    }

    func run(_ invocation: CommandInvocation) async throws -> CommandResult {
        lock.lock()
        _invocations.append(invocation)
        lock.unlock()
        return CommandResult(exitCode: 0)
    }
}
