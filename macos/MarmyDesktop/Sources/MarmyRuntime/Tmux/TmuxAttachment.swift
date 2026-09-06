import Foundation

/// The command that attaches a terminal to a running session.
///
/// The client is a normal shared attachment: no `-d`, so any terminal the user
/// already has attached keeps working, and quitting Marmy only ends this client,
/// never the session.
public struct TmuxAttachment: Sendable, Equatable {
    public var executablePath: String
    public var arguments: [String]
    /// Environment for the client process. A stale `TMUX` inherited from the
    /// pane Marmy was launched from would make tmux refuse to attach.
    public var environment: [String: String]

    public init(executablePath: String, arguments: [String], environment: [String: String]) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
    }

    /// SwiftTerm wants `KEY=value` strings.
    public var environmentStrings: [String] {
        environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    }
}

extension TmuxClient {
    /// Attaches to one exact session by its stable id.
    public func attachment(
        sessionID: String,
        termName: String = "xterm-256color",
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TmuxAttachment {
        var environment = baseEnvironment
        environment.removeValue(forKey: "TMUX")
        environment.removeValue(forKey: "TMUX_PANE")
        environment["TERM"] = termName
        return TmuxAttachment(
            executablePath: executablePath,
            arguments: server.arguments + ["attach-session", "-t", sessionID],
            environment: environment)
    }
}
