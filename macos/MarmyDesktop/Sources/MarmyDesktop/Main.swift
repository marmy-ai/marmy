import Foundation
import MarmyRuntime

/// Process entry point.
///
/// `--run-agent <spec>` is handled here, before any AppKit or SwiftUI type is
/// touched, so a pane started by tmux becomes the agent CLI without ever
/// bringing up a GUI. Everything else opens the app.
@main
enum MarmyDesktopMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == AgentTrampoline.flag {
            runAgent(arguments)
        }
        MarmyDesktopApp.main()
    }

    private static func runAgent(_ arguments: [String]) -> Never {
        guard arguments.count == 2 else {
            FileHandle.standardError.write(Data("usage: MarmyDesktop \(AgentTrampoline.flag) <spec.json>\n".utf8))
            exit(64)
        }
        do {
            try AgentTrampoline.run(specPath: arguments[1])
        } catch {
            AgentTrampoline.reportFailure(specPath: arguments[1], error: error)
            FileHandle.standardError.write(Data("marmy: \(error)\n".utf8))
            exit(70)
        }
    }
}
