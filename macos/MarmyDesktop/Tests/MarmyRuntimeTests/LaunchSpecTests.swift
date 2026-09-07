import XCTest
import MarmyCore
@testable import MarmyRuntime

final class LaunchSpecTests: XCTestCase {

    private func spec(
        arguments: [String] = ["--", "hello"],
        removals: [String] = ["CLAUDECODE"],
        additions: [String: String] = ["PATH": "/opt/homebrew/bin:/usr/bin"]
    ) -> LaunchSpec {
        LaunchSpec(
            executablePath: "/opt/homebrew/bin/claude",
            arguments: arguments,
            workingDirectory: "/tmp/work",
            environmentAdditions: additions,
            environmentRemovals: removals,
            topologyID: UUID(), nodeID: UUID(), generation: UUID())
    }

    func testEnvironmentKeepsTheFreshTmuxVariablesFromTheNewPane() {
        // The pane's own TMUX/TMUX_PANE are how the agent addresses the server
        // it was started on, including a non-default socket.
        let environment = AgentTrampoline.resolvedEnvironment(for: spec(), base: [
            "TMUX": "/private/tmp/tmux-501/marmy,123,4",
            "TMUX_PANE": "%7",
            "CLAUDECODE": "1",
            "ANTHROPIC_API_KEY": "secret",
            "PATH": "/usr/bin",
        ])

        XCTAssertEqual(environment["TMUX"], "/private/tmp/tmux-501/marmy,123,4")
        XCTAssertEqual(environment["TMUX_PANE"], "%7")
        XCTAssertNil(environment["CLAUDECODE"], "a launched Claude must not think it is inside another one")
        XCTAssertEqual(environment["ANTHROPIC_API_KEY"], "secret", "auth-related variables are preserved")
        XCTAssertEqual(environment["PATH"], "/opt/homebrew/bin:/usr/bin")
    }

    func testEmptyPATHFallsBackToSomethingUsable() {
        let environment = AgentTrampoline.resolvedEnvironment(
            for: spec(additions: [:]), base: ["PATH": ""])
        XCTAssertTrue(environment["PATH"]!.contains("/usr/bin"))
    }

    func testNULValuesAreRefusedRatherThanTruncated() {
        XCTAssertThrowsError(try AgentTrampoline.validateForExec(spec(arguments: ["--", "hi\u{0}there"])))
        XCTAssertThrowsError(try AgentTrampoline.validateForExec(spec(additions: ["A\u{0}B": "x"])))
        XCTAssertNoThrow(try AgentTrampoline.validateForExec(spec()))
    }

    func testSpecRoundTripsThroughJSON() throws {
        let original = spec(arguments: ["--model", "some-model", "--", "multi\nline `prompt` $HOME"])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LaunchSpec.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testNewerSpecVersionIsRejected() throws {
        var future = spec()
        future.version = LaunchSpec.currentVersion + 1
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        try JSONEncoder().encode(future).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try AgentTrampoline.loadSpec(at: url.path)) { error in
            guard case TrampolineError.unsupportedVersion = error else {
                return XCTFail("expected .unsupportedVersion, got \(error)")
            }
        }
    }

    func testUnreadableSpecIsReported() {
        XCTAssertThrowsError(try AgentTrampoline.loadSpec(at: "/nonexistent/spec.json")) { error in
            guard case TrampolineError.unreadableSpec = error else {
                return XCTFail("expected .unreadableSpec, got \(error)")
            }
        }
    }

    func testTrampolineFailureIsRecordedNextToTheSpec() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        AgentTrampoline.reportFailure(
            specPath: url.path, error: TrampolineError.executableMissing(path: "/opt/homebrew/bin/claude"))
        defer { try? FileManager.default.removeItem(atPath: AgentTrampoline.errorPath(forSpecAt: url.path)) }

        let text = try String(contentsOfFile: AgentTrampoline.errorPath(forSpecAt: url.path), encoding: .utf8)
        XCTAssertTrue(text.contains("/opt/homebrew/bin/claude"))
    }

    // MARK: - Argument vectors

    private func node(_ cli: AgentCLI, model: String = "", directory: String = "~/code") -> AgentNode {
        AgentNode(
            sessionName: "build", kind: .worker, cli: cli, model: model,
            workingDirectory: directory)
    }

    func testPromptIsPassedAfterAnEndOfOptionsMarker() {
        // A prompt the user edited to start with "-" is text, not a flag.
        let arguments = AgentCommand.arguments(for: node(.claude), initialPrompt: "--help me")
        XCTAssertEqual(arguments, ["--", "--help me"])
    }

    func testBlankModelMeansTheCLIDefault() {
        XCTAssertEqual(AgentCommand.arguments(for: node(.claude), initialPrompt: "hi"), ["--", "hi"])
        XCTAssertEqual(
            AgentCommand.arguments(for: node(.claude, model: " some-model "), initialPrompt: "hi"),
            ["--model", "some-model", "--", "hi"])
    }

    func testCodexIsGivenTheResolvedWorkingDirectory() {
        // Codex takes --cd literally; "~/code" would be a folder called "~".
        let arguments = AgentCommand.arguments(
            for: node(.codex), initialPrompt: "hi", workingDirectory: "/Users/x/code")
        XCTAssertEqual(arguments, ["--cd", "/Users/x/code", "--", "hi"])

        let expanded = AgentCommand.arguments(for: node(.codex), initialPrompt: "hi")
        XCTAssertEqual(expanded[1], NSString(string: "~/code").expandingTildeInPath)
        XCTAssertFalse(expanded[1].hasPrefix("~"))
    }

    func testNoPermissionBypassFlagIsEverPassed() {
        for cli in AgentCLI.allCases {
            let arguments = AgentCommand.arguments(for: node(cli), initialPrompt: "hi")
            XCTAssertFalse(arguments.contains { $0.contains("dangerously") || $0.contains("bypass") })
        }
    }

    func testEmptyPromptAddsNoPositionalArgument() {
        XCTAssertEqual(AgentCommand.arguments(for: node(.claude), initialPrompt: "   \n"), [])
        XCTAssertEqual(AgentCommand.arguments(for: node(.claude), initialPrompt: nil), [])
    }

    func testClaudeLaunchDropsInheritedClaudeCodeMarkers() {
        XCTAssertEqual(
            AgentCommand.environmentRemovals(for: node(.claude)),
            ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"])
        XCTAssertTrue(AgentCommand.environmentRemovals(for: node(.codex)).isEmpty)
    }
}
