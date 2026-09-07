import Foundation

/// The fixed executable tmux starts, plus its fixed leading arguments.
///
/// Only the spec path varies per launch, so nothing a user typed is ever parsed
/// by tmux or by a shell.
public struct TrampolineCommand: Sendable, Equatable {
    public var executablePath: String
    public var leadingArguments: [String]

    public init(executablePath: String, leadingArguments: [String] = []) {
        self.executablePath = executablePath
        self.leadingArguments = leadingArguments
    }

    public func arguments(specPath: String) -> [String] {
        leadingArguments + [specPath]
    }

    /// Prefers the `marmy-agent-launch` helper sitting beside the running
    /// binary, and otherwise re-enters this executable's own `--run-agent` path.
    public static func resolveDefault(
        executablePath: String = ProcessInfo.processInfo.arguments.first ?? "",
        fileManager: FileManager = .default
    ) -> TrampolineCommand {
        let selfPath = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().path
        let helper = URL(fileURLWithPath: selfPath)
            .deletingLastPathComponent()
            .appendingPathComponent("marmy-agent-launch")
            .path
        if fileManager.isExecutableFile(atPath: helper) {
            return TrampolineCommand(executablePath: helper, leadingArguments: [AgentTrampoline.flag])
        }
        return TrampolineCommand(executablePath: selfPath, leadingArguments: [AgentTrampoline.flag])
    }
}
