import Foundation

public enum RuntimeStoreError: Error, CustomStringConvertible {
    case unreadable(url: URL, detail: String)
    case corrupted(url: URL, detail: String)
    case unsupportedVersion(found: Int, supported: Int)
    case writeFailed(url: URL, detail: String)

    public var description: String {
        switch self {
        case .unreadable(let url, let detail):
            return "Could not read \(url.lastPathComponent): \(detail)"
        case .corrupted(let url, let detail):
            return "\(url.lastPathComponent) could not be read: \(detail)"
        case .unsupportedVersion(let found, let supported):
            return "Runtime ledger version \(found) is newer than this build reads (\(supported))."
        case .writeFailed(let url, let detail):
            return "Could not write \(url.lastPathComponent): \(detail)"
        }
    }
}

/// Bindings for every node Marmy has started or adopted.
public struct RuntimeLedger: Codable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var bindings: [AgentBinding]

    public init(version: Int = RuntimeLedger.currentVersion, bindings: [AgentBinding] = []) {
        self.version = version
        self.bindings = bindings
    }

    public func binding(nodeID: UUID) -> AgentBinding? {
        bindings.first { $0.nodeID == nodeID }
    }

    public mutating func upsert(_ binding: AgentBinding) {
        if let index = bindings.firstIndex(where: { $0.nodeID == binding.nodeID }) {
            bindings[index] = binding
        } else {
            bindings.append(binding)
        }
    }

    /// Drops Marmy's record of a node. The tmux session keeps running: metadata
    /// is the only thing being forgotten.
    @discardableResult
    public mutating func remove(nodeID: UUID) -> AgentBinding? {
        guard let index = bindings.firstIndex(where: { $0.nodeID == nodeID }) else { return nil }
        return bindings.remove(at: index)
    }
}

/// Private on-disk state for the runtime: the ledger plus the short-lived launch
/// spec files.
///
/// `MARMY_DATA_DIR` redirects everything, which is how tests and smoke runs stay
/// away from the user's real data.
public struct RuntimeStore: Sendable {
    public static let ledgerFileName = "runtime.json"
    public static let specsDirectoryName = "launch-specs"

    public let directoryURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    public static func defaultDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        if let override = environment["MARMY_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath, isDirectory: true)
        }
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MarmyDesktop", isDirectory: true)
    }

    public var ledgerURL: URL { directoryURL.appendingPathComponent(Self.ledgerFileName) }
    public var specsDirectoryURL: URL { directoryURL.appendingPathComponent(Self.specsDirectoryName, isDirectory: true) }

    public func loadLedger() throws -> RuntimeLedger {
        let data: Data
        do {
            data = try Data(contentsOf: ledgerURL)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            // Nothing has been launched yet. Any other read failure — a
            // permission problem, a bad disk — must not read as "no agents".
            return RuntimeLedger()
        } catch {
            throw RuntimeStoreError.unreadable(url: ledgerURL, detail: error.localizedDescription)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let ledger = try decoder.decode(RuntimeLedger.self, from: data)
            guard ledger.version <= RuntimeLedger.currentVersion else {
                throw RuntimeStoreError.unsupportedVersion(
                    found: ledger.version, supported: RuntimeLedger.currentVersion)
            }
            return ledger
        } catch let error as RuntimeStoreError {
            throw error
        } catch {
            throw RuntimeStoreError.corrupted(url: ledgerURL, detail: "\(error)")
        }
    }

    public func saveLedger(_ ledger: RuntimeLedger) throws {
        var ledger = ledger
        ledger.version = RuntimeLedger.currentVersion
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(ledger).write(to: ledgerURL, options: [.atomic])
        } catch {
            throw RuntimeStoreError.writeFailed(url: ledgerURL, detail: error.localizedDescription)
        }
    }

    /// Writes a launch spec readable only by this user. The trampoline deletes it
    /// as it starts the agent; `sweepStaleSpecs` clears anything a failed launch
    /// left behind.
    public func writeSpec(_ spec: LaunchSpec) throws -> URL {
        let url = specsDirectoryURL.appendingPathComponent("\(spec.generation.uuidString).json")
        do {
            // The directory is locked down before anything is written into it: a
            // spec holds a rendered prompt, and an atomic write lands as 0644
            // for the instant before it can be chmodded.
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: specsDirectoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: specsDirectoryURL.path)
            let data = try JSONEncoder().encode(spec)
            try data.write(to: url, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw RuntimeStoreError.writeFailed(url: url, detail: error.localizedDescription)
        }
        return url
    }

    public func removeSpec(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Removes spec files older than `age`. Anything younger might still be on
    /// its way into a starting pane.
    public func sweepStaleSpecs(olderThan age: TimeInterval = 3600, now: Date = Date()) {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: specsDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }

        for url in contents {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? now
            if now.timeIntervalSince(modified) > age {
                try? fileManager.removeItem(at: url)
            }
        }
    }
}
