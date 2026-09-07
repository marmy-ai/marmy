import Foundation

/// The shell a terminal node starts.
///
/// It is the user's own login shell when that can be trusted — an absolute path
/// to a real executable — and a sensible system shell otherwise. The path is
/// used as an argument vector, never interpolated into a command string.
public enum LoginShell {
    public static let fallbacks = ["/bin/zsh", "/bin/bash", "/bin/sh"]

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String? {
        if let shell = environment["SHELL"], shell.hasPrefix("/"), isRunnable(shell, fileManager) {
            return shell
        }
        return fallbacks.first { isRunnable($0, fileManager) }
    }

    /// `-l` so the shell reads the user's profile, exactly as Terminal.app does.
    public static let arguments = ["-l"]

    private static func isRunnable(_ path: String, _ fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        return fileManager.isExecutableFile(atPath: path)
    }
}
