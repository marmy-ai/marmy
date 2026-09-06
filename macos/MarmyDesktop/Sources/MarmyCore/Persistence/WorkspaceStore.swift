import Foundation

/// Why a workspace file could not be read or written.
///
/// Every case is surfaced to the user. Marmy never silently replaces an
/// unreadable file with an empty one — a bad decode is a bug or a downgrade,
/// and the user's teams are worth more than a clean launch.
public enum WorkspaceStoreError: Error, CustomStringConvertible {
    case unreadable(url: URL, underlying: Error)
    case corrupted(url: URL, detail: String)
    case unsupportedVersion(url: URL, found: Int, supported: Int)
    case encodingFailed(underlying: Error)
    case writeFailed(url: URL, underlying: Error)
    case noBackup(url: URL)

    public var description: String {
        switch self {
        case .unreadable(let url, let underlying):
            return "Could not read \(url.lastPathComponent): \(underlying.localizedDescription)"
        case .corrupted(let url, let detail):
            return "\(url.lastPathComponent) is not readable as a Marmy workspace: \(detail)"
        case .unsupportedVersion(let url, let found, let supported):
            return "\(url.lastPathComponent) was written by a newer version of Marmy Desktop "
                + "(file version \(found), this build reads \(supported)). Update the app instead of opening it."
        case .encodingFailed(let underlying):
            return "Could not encode the workspace: \(underlying.localizedDescription)"
        case .writeFailed(let url, let underlying):
            return "Could not write \(url.lastPathComponent): \(underlying.localizedDescription)"
        case .noBackup(let url):
            return "No backup exists next to \(url.lastPathComponent)."
        }
    }

    /// True when the previous good file is still on disk untouched.
    public var leftFileIntact: Bool {
        switch self {
        case .encodingFailed, .writeFailed: return true
        default: return false
        }
    }
}

/// Reads and writes the single workspace file.
///
/// Writes go to a temporary file in the same directory and are swapped in
/// atomically, and the file being replaced is copied to `workspace.backup.json`
/// first. A crashed or failed save therefore always leaves either the previous
/// contents or a recoverable backup — never a truncated file.
public struct WorkspaceStore: Sendable {
    public static let fileName = "workspace.json"
    public static let backupFileName = "workspace.backup.json"

    public let directoryURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    /// `~/Library/Application Support/MarmyDesktop`. Tests never use this.
    public static func defaultDirectory(
        fileManager: FileManager = .default,
        bundleIdentifier: String = "MarmyDesktop"
    ) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    public var fileURL: URL { directoryURL.appendingPathComponent(Self.fileName) }
    public var backupURL: URL { directoryURL.appendingPathComponent(Self.backupFileName) }

    public var fileExists: Bool { FileManager.default.fileExists(atPath: fileURL.path) }
    public var backupExists: Bool { FileManager.default.fileExists(atPath: backupURL.path) }

    // MARK: - Reading

    /// Loads the workspace. Throws when the file exists but cannot be trusted.
    public func load() throws -> Workspace {
        try load(from: fileURL)
    }

    /// Loads the backup written before the most recent successful save.
    public func loadBackup() throws -> Workspace {
        guard backupExists else { throw WorkspaceStoreError.noBackup(url: fileURL) }
        return try load(from: backupURL)
    }

    /// Loads the workspace, or returns a fresh starter workspace when no file
    /// exists yet. A file that exists but fails to decode still throws.
    public func loadOrStarter(_ makeStarter: () -> Workspace = Workspace.starter) throws -> Workspace {
        guard fileExists else { return makeStarter() }
        return try load()
    }

    private func load(from url: URL) throws -> Workspace {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw WorkspaceStoreError.unreadable(url: url, underlying: error)
        }

        // Read the version first so a file from a newer build reports a clear
        // upgrade message instead of a confusing field-level decode error.
        struct VersionProbe: Decodable { let version: Int }
        let decoder = JSONDecoder()
        do {
            let probe = try decoder.decode(VersionProbe.self, from: data)
            guard probe.version <= Workspace.currentVersion else {
                throw WorkspaceStoreError.unsupportedVersion(
                    url: url, found: probe.version, supported: Workspace.currentVersion)
            }
        } catch let error as WorkspaceStoreError {
            throw error
        } catch {
            throw WorkspaceStoreError.corrupted(url: url, detail: describe(error))
        }

        do {
            return try decoder.decode(Workspace.self, from: data)
        } catch {
            throw WorkspaceStoreError.corrupted(url: url, detail: describe(error))
        }
    }

    // MARK: - Writing

    /// Saves atomically, keeping the previous file as a backup.
    public func save(_ workspace: Workspace) throws {
        var workspace = workspace
        workspace.version = Workspace.currentVersion

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(workspace)
        } catch {
            // Nothing has touched the disk yet.
            throw WorkspaceStoreError.encodingFailed(underlying: error)
        }

        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            throw WorkspaceStoreError.writeFailed(url: fileURL, underlying: error)
        }

        if fileManager.fileExists(atPath: fileURL.path) {
            do {
                if fileManager.fileExists(atPath: backupURL.path) {
                    try fileManager.removeItem(at: backupURL)
                }
                try fileManager.copyItem(at: fileURL, to: backupURL)
            } catch {
                // A backup we could not refresh is not a reason to lose the save,
                // but it is a reason not to pretend everything is fine.
                throw WorkspaceStoreError.writeFailed(url: backupURL, underlying: error)
            }
        }

        do {
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            throw WorkspaceStoreError.writeFailed(url: fileURL, underlying: error)
        }
    }

    private func describe(_ error: Error) -> String {
        if let decodingError = error as? DecodingError {
            switch decodingError {
            case .dataCorrupted(let context):
                return context.debugDescription
            case .keyNotFound(let key, _):
                return "missing field \u{22}\(key.stringValue)\u{22}"
            case .typeMismatch(_, let context), .valueNotFound(_, let context):
                return context.debugDescription
            @unknown default:
                return "\(decodingError)"
            }
        }
        return error.localizedDescription
    }
}
