import Foundation
import MarmyCore

/// Turns a node plus its rendered prompt into the exact argument vector for its
/// CLI.
///
/// Only flags the local CLIs actually document are used, a blank model means the
/// CLI's own default, and no permission-bypass flag is ever passed.
public enum AgentCommand {

    /// `workingDirectory` is the resolved absolute path the agent will actually
    /// start in — never the unexpanded `~/…` the user typed, which Codex would
    /// take literally.
    public static func arguments(
        for node: AgentNode,
        initialPrompt: String?,
        workingDirectory: String? = nil
    ) -> [String] {
        // A terminal is a login shell and nothing else: no model, and no prompt
        // — text handed to a shell is a command, not an instruction.
        guard node.cli.isAutonomousAgent else { return LoginShell.arguments }

        var arguments: [String] = []
        let model = node.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty {
            arguments += ["--model", model]
        }
        switch node.cli {
        case .claude, .terminal:
            break
        case .codex:
            arguments += ["--cd", workingDirectory ?? NSString(string: node.workingDirectory).expandingTildeInPath]
        }
        if let initialPrompt, !initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // End of options: a prompt the user edited into starting with "-"
            // is text, not a flag, and must never be parsed as one.
            arguments.append("--")
            arguments.append(initialPrompt)
        }
        return arguments
    }

    /// Variables to drop before exec.
    ///
    /// Claude Code sets `CLAUDECODE` in its own child processes; inheriting it
    /// would make a freshly launched Claude think it is running inside another
    /// one.
    public static func environmentRemovals(for node: AgentNode) -> [String] {
        switch node.cli {
        case .claude: return ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"]
        case .codex: return []
        case .terminal:
            // A shell someone may well open Claude in by hand. Inheriting these
            // would make that Claude think it is running inside another one.
            return ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"]
        }
    }
}
