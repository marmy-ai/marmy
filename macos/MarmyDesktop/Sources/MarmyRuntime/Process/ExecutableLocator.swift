import Foundation

public enum ExecutableLookupError: Error, CustomStringConvertible, Equatable {
    case notFound(name: String, searched: [String])
    case notExecutable(path: String)

    public var description: String {
        switch self {
        case .notFound(let name, let searched):
            return "Could not find \u{22}\(name)\u{22} on PATH. Install it, or add its folder to PATH "
                + "and reopen Marmy Desktop. Looked in: \(searched.joined(separator: ", "))."
        case .notExecutable(let path):
            return "\(path) exists but is not an executable file."
        }
    }
}

/// Finds command line tools without ever asking a shell.
///
/// A GUI app inherits a thin PATH from launchd, so the usual install locations
/// are searched as well. Nothing here interpolates into a shell command.
public struct ExecutableLocator: Sendable {
    /// Where Homebrew, pipx-style installs, and the system keep binaries.
    public static let fallbackDirectories = [
        "~/.local/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
    ]

    public let searchDirectories: [String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let inherited = (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
        self.init(searchDirectories: inherited + Self.fallbackDirectories)
    }

    public init(searchDirectories: [String]) {
        var seen: Set<String> = []
        self.searchDirectories = searchDirectories
            .map { NSString(string: $0).expandingTildeInPath }
            .filter { seen.insert($0).inserted }
    }

    /// Absolute path of `name`, or `nil` when it is not installed.
    /// A name containing a slash is treated as a path and only checked.
    public func locate(_ name: String) -> String? {
        if name.contains("/") {
            return isRunnable(name) ? NSString(string: name).expandingTildeInPath : nil
        }
        for directory in searchDirectories {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if isRunnable(candidate) { return candidate }
        }
        return nil
    }

    public func locateOrThrow(_ name: String) throws -> String {
        if let path = locate(name) { return path }
        if name.contains("/"), FileManager.default.fileExists(atPath: name) {
            throw ExecutableLookupError.notExecutable(path: name)
        }
        throw ExecutableLookupError.notFound(name: name, searched: searchDirectories)
    }

    /// PATH to hand a launched agent, so it finds the same tools Marmy did.
    public var launchPATH: String {
        searchDirectories.joined(separator: ":")
    }

    private func isRunnable(_ path: String) -> Bool {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        return fileManager.isExecutableFile(atPath: path)
    }
}
