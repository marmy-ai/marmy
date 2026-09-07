import AppKit
import Foundation
import MarmyRuntime
import UniformTypeIdentifiers

/// Where images pasted or dropped into a terminal are kept.
///
/// An agent reads the file off disk, so the file has to still be there when it
/// gets round to it — after a reconnect, after a restart, tomorrow. Nothing here
/// deletes anything: a path that was handed to an agent stays valid.
///
/// Files are written where only this user can read them.
public struct AttachmentStore: Sendable {
    public static let directoryName = "pasted-images"

    public let directoryURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    public static func `default`(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> AttachmentStore {
        let base: URL
        if let override = environment["MARMY_DATA_DIR"], !override.isEmpty {
            base = URL(fileURLWithPath: NSString(string: override).expandingTildeInPath, isDirectory: true)
        } else {
            base = (fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support"))
                .appendingPathComponent("MarmyDesktop", isDirectory: true)
        }
        return AttachmentStore(directoryURL: base.appendingPathComponent(directoryName, isDirectory: true))
    }

    public enum Failure: Error, CustomStringConvertible {
        case unsupported
        case write(String)

        public var description: String {
            switch self {
            case .unsupported: return "That is not an image Marmy can save."
            case .write(let detail): return "The image could not be saved: \(detail)"
            }
        }
    }

    /// A folder of its own for one drop, so two files called Screenshot.png
    /// from different drops cannot overwrite each other.
    public func makeDropDirectory(id: UUID = UUID()) throws -> URL {
        try prepareDirectory()
        let url = directoryURL.appendingPathComponent("dropped-\(id.uuidString.lowercased())")
        do {
            // Not `withIntermediateDirectories`: this folder must be a new one,
            // so a file arriving in it cannot land on top of an earlier one.
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        } catch {
            throw Failure.write(error.localizedDescription)
        }
        return url
    }

    /// Makes sure the folder exists and only this user can read it.
    public func prepareDirectory() throws {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: directoryURL, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        } catch {
            throw Failure.write(error.localizedDescription)
        }
    }

    /// Saves image data and returns the file. PNG and TIFF arrive as they are;
    /// anything else AppKit understands is written out as PNG.
    @discardableResult
    public func save(imageData data: Data, preferredType: UTType?, now: Date = Date()) throws -> URL {
        let fileManager = FileManager.default
        try prepareDirectory()

        let (payload, ext) = try encode(data, preferredType: preferredType)
        let stamp = Self.stampFormatter.string(from: now)
        let url = directoryURL.appendingPathComponent(
            "\(stamp)-\(UUID().uuidString.prefix(8).lowercased()).\(ext)")
        do {
            try payload.write(to: url, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw Failure.write(error.localizedDescription)
        }
        return url
    }

    /// Whatever it claims to be, it has to actually be an image.
    private func encode(_ data: Data, preferredType: UTType?) throws -> (Data, String) {
        guard let rep = NSBitmapImageRep(data: data) else { throw Failure.unsupported }
        if preferredType == .png, Self.isPNG(data) { return (data, "png") }
        guard let png = rep.representation(using: .png, properties: [:]) else { throw Failure.unsupported }
        return (png, "png")
    }

    /// PNG's own signature, so bytes labelled PNG are checked rather than
    /// believed.
    static func isPNG(_ data: Data) -> Bool {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count > signature.count else { return false }
        return Array(data.prefix(signature.count)) == signature
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()
}

/// Turns a file path into something safe to type at a shell prompt.
public enum ShellQuoting {
    /// Single-quoted, with any single quote in the path escaped. A path with
    /// spaces, quotes, or `$` arrives at the agent exactly as it is on disk.
    public static func quote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// True for a path that is safe to type at a prompt.
    ///
    /// A newline would be read as Return by a program without bracketed paste,
    /// and an escape could end a bracketed paste early and let the rest be read
    /// as keystrokes. Neither is worth risking for a file name.
    public static func isTypable(_ path: String) -> Bool {
        InsertSafety.isSafe(path)
    }
}
