import Foundation

/// What a launched pane should turn into.
///
/// tmux runs a fixed trampoline with a fixed flag and this file's path. The
/// prompt, model, and every other piece of user data live inside the JSON,
/// never in an argument vector that tmux's own command parser reads.
public struct LaunchSpec: Codable, Sendable, Hashable {
    public static let currentVersion = 1

    public var version: Int
    /// Absolute path of the CLI to become. Resolved before the spec is written.
    public var executablePath: String
    /// Arguments for that CLI, including the rendered initial prompt.
    public var arguments: [String]
    public var workingDirectory: String
    /// Variables to set for the agent.
    public var environmentAdditions: [String: String]
    /// Variables to drop before exec, such as `CLAUDECODE` inherited from Marmy.
    public var environmentRemovals: [String]
    public var topologyID: UUID
    public var nodeID: UUID
    public var generation: UUID

    public init(
        version: Int = LaunchSpec.currentVersion,
        executablePath: String,
        arguments: [String],
        workingDirectory: String,
        environmentAdditions: [String: String] = [:],
        environmentRemovals: [String] = [],
        topologyID: UUID,
        nodeID: UUID,
        generation: UUID
    ) {
        self.version = version
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environmentAdditions = environmentAdditions
        self.environmentRemovals = environmentRemovals
        self.topologyID = topologyID
        self.nodeID = nodeID
        self.generation = generation
    }
}

public enum TrampolineError: Error, CustomStringConvertible, Equatable {
    case unreadableSpec(path: String, detail: String)
    case unsupportedVersion(found: Int, supported: Int)
    case executableMissing(path: String)
    case workingDirectoryMissing(path: String)
    case execFailed(path: String, errno: Int32)
    case embeddedNUL(field: String)

    public var description: String {
        switch self {
        case .unreadableSpec(let path, let detail):
            return "Could not read launch spec at \(path): \(detail)"
        case .unsupportedVersion(let found, let supported):
            return "Launch spec version \(found) is newer than this build understands (\(supported))."
        case .executableMissing(let path):
            return "The agent CLI is no longer at \(path)."
        case .workingDirectoryMissing(let path):
            return "Working directory \(path) no longer exists."
        case .execFailed(let path, let code):
            return "Could not start \(path): errno \(code)."
        case .embeddedNUL(let field):
            return "\(field) contains a NUL character, which cannot be passed to a program."
        }
    }
}

/// The fixed program tmux starts, which reads a spec and becomes the CLI.
///
/// Nothing here evaluates a shell. The agent process replaces this one through
/// `execve`, so the CLI ends up as the pane's own process and outlives Marmy.
public enum AgentTrampoline {
    /// The flag both the sidecar helper and the app itself answer to.
    public static let flag = "--run-agent"

    /// Environment for the agent: what the pane already has, minus what the spec
    /// removes, plus what it adds.
    ///
    /// `TMUX` and `TMUX_PANE` come from the freshly created pane and are kept
    /// deliberately, so the agent addresses the same server — including a
    /// non-default socket — that Marmy started it on.
    public static func resolvedEnvironment(
        for spec: LaunchSpec,
        base: [String: String],
        fallbackPATH: String = ExecutableLocator.fallbackDirectories.joined(separator: ":")
    ) -> [String: String] {
        var environment = base
        for key in spec.environmentRemovals {
            environment.removeValue(forKey: key)
        }
        for (key, value) in spec.environmentAdditions {
            environment[key] = value
        }
        if (environment["PATH"] ?? "").isEmpty {
            environment["PATH"] = fallbackPATH
        }
        return environment
    }

    /// C strings end at the first NUL, so a value containing one would be
    /// silently truncated on its way to the CLI. Refuse instead.
    public static func validateForExec(_ spec: LaunchSpec) throws {
        if spec.executablePath.contains("\0") { throw TrampolineError.embeddedNUL(field: "The CLI path") }
        if spec.workingDirectory.contains("\0") { throw TrampolineError.embeddedNUL(field: "The working directory") }
        for (index, argument) in spec.arguments.enumerated() where argument.contains("\0") {
            throw TrampolineError.embeddedNUL(field: "Argument \(index + 1)")
        }
        for (key, value) in spec.environmentAdditions where key.contains("\0") || value.contains("\0") {
            throw TrampolineError.embeddedNUL(field: "Environment variable \(key)")
        }
    }

    /// Where a failing trampoline leaves its reason.
    ///
    /// When exec fails the pane exits, and tmux takes the session with it, so
    /// there is nothing left on screen to read. The launcher picks this file up
    /// and reports what actually went wrong.
    public static func errorPath(forSpecAt specPath: String) -> String {
        specPath + ".error"
    }

    public static func reportFailure(specPath: String, error: Error) {
        let text = "\(error)\n"
        try? text.write(toFile: errorPath(forSpecAt: specPath), atomically: true, encoding: .utf8)
    }

    public static func loadSpec(at path: String) throws -> LaunchSpec {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw TrampolineError.unreadableSpec(path: path, detail: error.localizedDescription)
        }
        let spec: LaunchSpec
        do {
            spec = try JSONDecoder().decode(LaunchSpec.self, from: data)
        } catch {
            throw TrampolineError.unreadableSpec(path: path, detail: "\(error)")
        }
        guard spec.version <= LaunchSpec.currentVersion else {
            throw TrampolineError.unsupportedVersion(found: spec.version, supported: LaunchSpec.currentVersion)
        }
        return spec
    }

    /// Reads the spec, deletes it, and becomes the agent. Returns only on failure.
    public static func run(specPath: String, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Never {
        let spec = try loadSpec(at: specPath)
        try validateForExec(spec)

        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: spec.executablePath) else {
            throw TrampolineError.executableMissing(path: spec.executablePath)
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: spec.workingDirectory, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw TrampolineError.workingDirectoryMissing(path: spec.workingDirectory)
        }

        // The spec has served its purpose; it holds the rendered prompt, so it
        // goes away at the last moment it is still safe to remove it.
        try? fileManager.removeItem(atPath: specPath)

        guard fileManager.changeCurrentDirectoryPath(spec.workingDirectory) else {
            throw TrampolineError.workingDirectoryMissing(path: spec.workingDirectory)
        }

        let resolved = resolvedEnvironment(for: spec, base: environment)
        exec(path: spec.executablePath, arguments: [spec.executablePath] + spec.arguments, environment: resolved)
        throw TrampolineError.execFailed(path: spec.executablePath, errno: errno)
    }

    /// `execve` with no shell anywhere in the path.
    private static func exec(path: String, arguments: [String], environment: [String: String]) {
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = environment
            .sorted { $0.key < $1.key }
            .map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        execve(path, &argv, &envp)
    }
}
