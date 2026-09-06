import Foundation
import MarmyCore
import MarmyRuntime
@testable import MarmyUI

/// Scripted tmux, so these tests never touch a server.
final class FakeRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var invocations: [CommandInvocation] = []
    private var responses: [String: CommandResult] = [:]
    /// Seconds each call takes, for tests about what happens meanwhile.
    var delay: TimeInterval = 0

    func stub(_ subcommand: String, _ result: CommandResult) {
        lock.lock(); defer { lock.unlock() }
        responses[subcommand] = result
    }

    func calls(of name: String) -> [CommandInvocation] {
        lock.lock(); defer { lock.unlock() }
        return invocations.filter { subcommand(of: $0.arguments) == name }
    }

    func run(_ invocation: CommandInvocation) async throws -> CommandResult {
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        lock.lock()
        invocations.append(invocation)
        let name = subcommand(of: invocation.arguments) ?? ""
        let result = responses[name]
        lock.unlock()
        return result ?? CommandResult(exitCode: 0)
    }

    private func subcommand(of arguments: [String]) -> String? {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "-L" || argument == "-S" || argument == "-f" { index += 2; continue }
            if argument.hasPrefix("-") { index += 1; continue }
            return argument
        }
        return nil
    }
}

enum Fixture {
    static let identity = TmuxServerIdentity(pid: 77, socketPath: "/tmp/tmux-501/default", startTime: 1700)

    static func record(_ fields: [String]) -> String {
        fields.map { "\(Data($0.utf8).count):\($0)" }.joined()
    }

    static func output(_ records: [[String]]) -> String {
        records.isEmpty ? "" : records.map(record).joined(separator: "\n") + "\n"
    }
}

/// A workspace, model, and environment wired to scripted tmux and speech.
@MainActor
struct TestBench {
    let root: URL
    let model: AppModel
    let env: AppEnvironment
    let speech: ScriptedSpeechEngine
    let runner: FakeRunner
    let topology: Topology

    init(sessionsRunning: Bool = true) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarmyUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        runner = FakeRunner()
        runner.stub("display-message", CommandResult(
            exitCode: 0,
            standardOutput: Fixture.record(["77", "/tmp/tmux-501/default", "1700"])))

        var workspace = Workspace.starter()
        workspace.operatorName = "Marwan"
        var team = workspace.topologyTemplate(DefaultTemplates.ID.starterTeam)!
            .instantiate(name: "Team")
        for index in team.nodes.indices {
            team.nodes[index].workingDirectory = root.path
        }
        workspace.upsert(team)
        topology = team

        if sessionsRunning {
            runner.stub("list-sessions", CommandResult(
                exitCode: 0,
                standardOutput: Fixture.output(team.nodes.enumerated().map { index, node in
                    ["$\(index)", node.sessionName, "1700", "0", "1"]
                })))
            runner.stub("list-panes", CommandResult(
                exitCode: 0,
                standardOutput: Fixture.output(team.nodes.enumerated().map { index, node in
                    ["%\(index)", "$\(index)", node.sessionName, "@0", "9", "cat", "/tmp", "1", "1", "0"]
                })))
            runner.stub("list-clients", CommandResult(
                exitCode: 0,
                standardOutput: Fixture.output(team.nodes.enumerated().map { index, node in
                    ["4\(index)", "/dev/ttys00\(index)", "$\(index)", node.sessionName, "%\(index)"]
                })))
        } else {
            runner.stub("list-sessions", CommandResult(exitCode: 0))
            runner.stub("list-panes", CommandResult(exitCode: 0))
        }

        let workspaceStore = WorkspaceStore(directoryURL: root.appendingPathComponent("workspace"))
        try workspaceStore.save(workspace)
        let runtime = try AgentRuntime(
            tmux: TmuxClient(executablePath: "/usr/bin/true", runner: runner),
            locator: ExecutableLocator(searchDirectories: [root.path]),
            store: RuntimeStore(directoryURL: root.appendingPathComponent("runtime")))

        model = AppModel(store: workspaceStore, runtime: runtime)
        speech = ScriptedSpeechEngine()
        env = AppEnvironment(model: model, speechEngine: speech)
    }

    var manager: AgentNode { topology.roots[0] }
    var workers: [AgentNode] { topology.children(of: manager.id) }

    /// Records bindings as though the team had been launched.
    func bindEverything() async throws {
        for (index, node) in topology.nodes.enumerated() {
            _ = try await model.runtime.adopt(
                sessionName: node.sessionName, nodeID: node.id, topology: topology, cli: node.cli)
            _ = index
        }
        await model.refresh()
    }

    func cleanUp() {
        env.shutDown()
        try? FileManager.default.removeItem(at: root)
    }
}
