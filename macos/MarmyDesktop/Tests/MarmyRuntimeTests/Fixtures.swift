import Foundation
import MarmyCore
@testable import MarmyRuntime

// MARK: - Command runner fake

/// Records every subprocess Marmy would have run and replies with scripted
/// output, so failure paths are testable without a tmux server.
final class FakeCommandRunner: CommandRunning, @unchecked Sendable {
    struct Call: Sendable {
        var executable: String
        var arguments: [String]
        var standardInput: Data?

        /// The tmux subcommand, with socket arguments skipped.
        var subcommand: String? { FakeCommandRunner.subcommand(of: arguments) }
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    /// Runs just before a call is answered, so a test can change the world
    /// halfway through a delivery.
    var beforeCall: (@Sendable (Call) -> Void)?
    private var responses: [String: [CommandResult]] = [:]
    private var errors: [String: Error] = [:]

    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    var subcommands: [String] { calls.compactMap(\.subcommand) }

    /// Replies to `subcommand` with `result`. Queued replies are consumed in
    /// order; the last one repeats.
    func stub(_ subcommand: String, _ result: CommandResult) {
        lock.lock(); defer { lock.unlock() }
        responses[subcommand, default: []].append(result)
    }

    /// Discards anything queued for `subcommand` and answers with `result` from
    /// now on. Used when a test changes the world midway.
    func replace(_ subcommand: String, with result: CommandResult) {
        lock.lock(); defer { lock.unlock() }
        responses[subcommand] = [result]
    }

    func fail(_ subcommand: String, with error: Error) {
        lock.lock(); defer { lock.unlock() }
        errors[subcommand] = error
    }

    func calls(of subcommand: String) -> [Call] {
        calls.filter { $0.subcommand == subcommand }
    }

    func run(_ invocation: CommandInvocation) async throws -> CommandResult {
        let call = Call(
            executable: invocation.executable,
            arguments: invocation.arguments,
            standardInput: invocation.standardInput)
        beforeCall?(call)
        lock.lock()
        _calls.append(Call(
            executable: invocation.executable,
            arguments: invocation.arguments,
            standardInput: invocation.standardInput))
        let name = FakeCommandRunner.subcommand(of: invocation.arguments) ?? ""
        let error = errors[name]
        var queued = responses[name] ?? []
        let result = queued.first
        if queued.count > 1 {
            queued.removeFirst()
            responses[name] = queued
        }
        lock.unlock()

        if let error { throw error }
        return result ?? CommandResult(exitCode: 0)
    }

    static func subcommand(of arguments: [String]) -> String? {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "-L" || argument == "-S" || argument == "-f" {
                index += 2
                continue
            }
            if argument.hasPrefix("-") {
                index += 1
                continue
            }
            return argument
        }
        return nil
    }
}

// MARK: - tmux output fixtures

enum TmuxFixtures {
    /// Encodes fields the way `#{n:field}:#{field}` does.
    static func record(_ fields: [String]) -> String {
        fields.map { "\(Data($0.utf8).count):\($0)" }.joined()
    }

    static func output(_ records: [[String]]) -> String {
        records.map(record).joined(separator: "\n") + (records.isEmpty ? "" : "\n")
    }

    static func serverIdentity(pid: Int32 = 4242, socketPath: String = "/tmp/tmux-501/default", startTime: Int = 1700)
        -> CommandResult
    {
        CommandResult(exitCode: 0, standardOutput: record(["\(pid)", socketPath, "\(startTime)"]))
    }

    static let identity = TmuxServerIdentity(pid: 4242, socketPath: "/tmp/tmux-501/default", startTime: 1700)

    static func sessions(_ sessions: [(id: String, name: String)]) -> CommandResult {
        CommandResult(exitCode: 0, standardOutput: output(sessions.map { [$0.id, $0.name, "1700", "0", "1"] }))
    }

    static func panes(
        _ panes: [(pane: String, session: String, name: String)],
        dead: Bool = false
    ) -> CommandResult {
        CommandResult(exitCode: 0, standardOutput: output(panes.map {
            [$0.pane, $0.session, $0.name, "@0", "999", "cat", "/tmp", "1", "1", dead ? "1" : "0"]
        }))
    }

    static func started(session: String, name: String, pane: String) -> CommandResult {
        CommandResult(exitCode: 0, standardOutput: record([session, name, pane]))
    }

    static let noServer = CommandResult(
        exitCode: 1,
        standardError: "error connecting to /private/tmp/tmux-501/default (No such file or directory)")

    static let permissionDenied = CommandResult(
        exitCode: 1,
        standardError: "error connecting to /private/tmp/tmux-501/default (Permission denied)")
}

// MARK: - Domain fixtures

enum Team {
    static let managerID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    static let workerID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    static let topologyID = UUID(uuidString: "00000000-0000-4000-8000-000000000100")!

    static func topology(workingDirectory: String) -> Topology {
        let manager = AgentNode(
            id: managerID, sessionName: "lead", displayName: "Lead", kind: .manager,
            roleTitle: "Reviews and commits", cli: .claude, workingDirectory: workingDirectory,
            promptTemplateID: DefaultTemplates.ID.managerPrompt)
        let worker = AgentNode(
            id: workerID, sessionName: "build", displayName: "Build", kind: .worker,
            roleTitle: "Implementation", cli: .claude, workingDirectory: workingDirectory,
            parentID: managerID, promptTemplateID: DefaultTemplates.ID.workerPrompt)
        return Topology(id: topologyID, name: "Mac work", nodes: [manager, worker])
    }

    static func workspace(workingDirectory: String) -> Workspace {
        var workspace = Workspace.starter()
        workspace.operatorName = "Marwan"
        workspace.upsert(topology(workingDirectory: workingDirectory))
        return workspace
    }
}

/// A scratch directory plus fake `claude`/`codex` executables, so preflight can
/// find a CLI without anything real being installed or run.
struct TestEnvironment {
    let root: URL
    let binDirectory: URL
    let workingDirectory: URL
    let dataDirectory: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarmyRuntimeTests-\(UUID().uuidString)", isDirectory: true)
        binDirectory = root.appendingPathComponent("bin", isDirectory: true)
        workingDirectory = root.appendingPathComponent("work", isDirectory: true)
        dataDirectory = root.appendingPathComponent("data", isDirectory: true)
        for url in [binDirectory, workingDirectory, dataDirectory] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        for name in ["claude", "codex", "tmux"] {
            try writeExecutable(named: name, contents: "#!/bin/sh\nexit 0\n")
        }
    }

    @discardableResult
    func writeExecutable(named name: String, contents: String) throws -> URL {
        let url = binDirectory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    var locator: ExecutableLocator { ExecutableLocator(searchDirectories: [binDirectory.path]) }
    var store: RuntimeStore { RuntimeStore(directoryURL: dataDirectory) }
    var trampoline: TrampolineCommand {
        TrampolineCommand(executablePath: binDirectory.appendingPathComponent("tmux").path)
    }
    var tmuxPath: String { binDirectory.appendingPathComponent("tmux").path }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}
