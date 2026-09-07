import Foundation
import MarmyRuntime

// The fixed program tmux starts. It reads a launch spec written by Marmy
// Desktop and becomes the agent CLI through execve. It evaluates no shell, and
// makes no network or model call of its own.
//
//   marmy-agent-launch --run-agent /path/to/spec.json

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2, arguments[0] == AgentTrampoline.flag else {
    FileHandle.standardError.write(Data("usage: marmy-agent-launch \(AgentTrampoline.flag) <spec.json>\n".utf8))
    exit(64)  // EX_USAGE
}

do {
    try AgentTrampoline.run(specPath: arguments[1])
} catch {
    // Exiting here ends the pane, and tmux ends the session with it, so the
    // reason is written next to the spec for Marmy to read and show.
    AgentTrampoline.reportFailure(specPath: arguments[1], error: error)
    FileHandle.standardError.write(Data("marmy: \(error)\n".utf8))
    exit(70)  // EX_SOFTWARE
}
