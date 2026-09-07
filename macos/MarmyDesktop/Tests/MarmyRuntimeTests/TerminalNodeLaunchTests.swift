import XCTest
import MarmyCore
@testable import MarmyRuntime

/// Launching a terminal node: a login shell, no prompt, nothing sent.
final class TerminalNodeLaunchTests: XCTestCase {

    private var environment: TestEnvironment!

    override func setUpWithError() throws {
        environment = try TestEnvironment()
    }

    override func tearDownWithError() throws {
        environment.cleanUp()
    }

    private func terminalNode(directory: String) -> AgentNode {
        AgentNode(
            sessionName: "harness", displayName: "Harness", kind: .worker,
            cli: .terminal, model: "ignored", workingDirectory: directory)
    }

    func testTheArgumentVectorIsJustALoginShell() {
        let node = terminalNode(directory: "/tmp")
        let arguments = AgentCommand.arguments(for: node, initialPrompt: "you are an agent")

        XCTAssertEqual(arguments, ["-l"], "no model flag, and no prompt handed to a shell")
        XCTAssertTrue(AgentCommand.environmentRemovals(for: node).isEmpty)
    }

    func testPreflightUsesTheLoginShellAndPlansNoPrompt() throws {
        let directory = environment.workingDirectory.path
        var topology = Team.topology(workingDirectory: directory)
        topology.nodes[1].cli = .terminal
        let workspace = Team.workspace(workingDirectory: directory)

        let report = LaunchPreflight.evaluate(
            topology: topology,
            workspace: workspace,
            liveSessions: [],
            states: [:],
            bindings: [:],
            locator: environment.locator,
            trampoline: environment.trampoline)

        XCTAssertFalse(report.isBlocked, "\(report.errors.map(\.message))")
        let plan = try XCTUnwrap(report.plans.first { $0.nodeID == Team.workerID })
        XCTAssertEqual(plan.arguments, ["-l"])
        XCTAssertTrue(plan.initialPrompt.isEmpty, "a shell is started empty")
        XCTAssertEqual(plan.executablePath, LoginShell.resolve())
        XCTAssertTrue(plan.executablePath.hasPrefix("/"))
    }

    func testAMissingAgentCLIStillBlocksButAShellDoesNot() {
        let directory = environment.workingDirectory.path
        var topology = Team.topology(workingDirectory: directory)
        topology.nodes[0].cli = .terminal   // the manager is a shell
        let workspace = Team.workspace(workingDirectory: directory)

        // Nothing is installed at all: the agent still fails, the shell does not.
        let report = LaunchPreflight.evaluate(
            topology: topology,
            workspace: workspace,
            liveSessions: [],
            states: [:],
            bindings: [:],
            locator: ExecutableLocator(searchDirectories: ["/nonexistent"]),
            trampoline: environment.trampoline)

        XCTAssertTrue(report.errors.contains { $0.kind == .cliMissing(name: "claude") })
        XCTAssertTrue(report.plans.contains { $0.nodeID == Team.managerID }, "the shell can still start")
    }

    func testOtherAgentsAreToldItIsAManualTerminal() throws {
        let directory = environment.workingDirectory.path
        var topology = Team.topology(workingDirectory: directory)
        topology.nodes[1].cli = .terminal
        let workspace = Team.workspace(workingDirectory: directory)

        let prompt = try BootstrapPrompt.render(
            for: topology.nodes[0], in: topology, workspace: workspace)

        XCTAssertTrue(prompt.contains("a manual terminal a person uses; do not send it messages"),
                      prompt)
    }

    func testTheShellIsAnExistingAbsoluteExecutable() throws {
        let shell = try XCTUnwrap(LoginShell.resolve())
        XCTAssertTrue(shell.hasPrefix("/"))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: shell))
    }

    func testAnUntrustworthyShellVariableIsIgnored() {
        XCTAssertEqual(
            LoginShell.resolve(environment: ["SHELL": "zsh; rm -rf /"]),
            LoginShell.fallbacks.first { FileManager.default.isExecutableFile(atPath: $0) },
            "a relative or odd value is not used as a program")
        XCTAssertEqual(
            LoginShell.resolve(environment: ["SHELL": "/definitely/not/here"]),
            LoginShell.fallbacks.first { FileManager.default.isExecutableFile(atPath: $0) })
    }
}
