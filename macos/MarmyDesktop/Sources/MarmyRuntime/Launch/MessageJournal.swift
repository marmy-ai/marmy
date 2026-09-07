import Foundation
import MarmyCore

/// Something Marmy sent, or tried to send, to an agent.
///
/// Entries are written before anything is dispatched and never edited except to
/// record what happened to that same entry. The payload is exactly what was
/// handed over — not a preview, not a re-render — so "what did this agent
/// actually get told?" always has an answer.
public struct JournalEntry: Codable, Identifiable, Hashable, Sendable {

    public enum Kind: String, Codable, Sendable {
        /// The prompt an agent was started with.
        case launchPrompt
        /// Dictation the user put into the agent's prompt.
        case dictation
        /// A team change Marmy told a manager about.
        case rosterUpdate
        /// A message the user sent from Marmy with Return.
        case userMessage
    }

    public enum Status: String, Codable, Sendable {
        /// Written down, not yet attempted.
        case prepared
        /// Handed to tmux, outcome not yet recorded. Anything left in this state
        /// by a previous run is uncertain, not untried.
        case sending
        /// Replaced by a newer update before it was ever sent.
        case superseded
        /// Thrown away by the user before it was ever sent.
        case discarded
        /// Put into the agent's prompt. Not sent: the user presses Return.
        case pasted
        /// Handed to tmux with Return. That is delivery, not comprehension —
        /// nobody can say from here whether the agent read or understood it.
        case submitted
        /// Did not happen. Safe to try again.
        case failed
        /// May or may not have arrived. Never retried automatically.
        case uncertain

        public var isFinished: Bool {
            self != .prepared && self != .sending
        }

        /// Whether this entry was never handed to tmux, so nothing about it can
        /// be rewritten by mistake.
        public var wasNeverAttempted: Bool {
            self == .prepared || self == .superseded || self == .discarded
        }
    }

    public var id: UUID
    public var kind: Kind
    public var status: Status
    public var createdAt: Date
    public var updatedAt: Date
    public var topologyID: UUID?
    public var nodeID: UUID?
    /// Where it was going, as it was at the time.
    public var sessionName: String
    public var sessionID: String
    public var paneID: String
    /// The tmux server it was going to. Session ids start over on a new server,
    /// so the server is part of saying where something went.
    public var serverPID: Int32?
    public var serverStartTime: Int?
    public var generation: UUID?
    /// Exactly what was handed over.
    public var payload: String
    /// Why it failed, or what is uncertain about it.
    public var detail: String?
    /// The attempt this one replaces, when a message is tried again against a
    /// terminal that has since changed. The earlier attempt keeps its own
    /// recipient and payload exactly as they were.
    public var previousAttemptID: UUID?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        status: Status = .prepared,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        topologyID: UUID? = nil,
        nodeID: UUID? = nil,
        sessionName: String,
        sessionID: String,
        paneID: String,
        server: TmuxServerIdentity? = nil,
        generation: UUID? = nil,
        payload: String,
        detail: String? = nil,
        previousAttemptID: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.topologyID = topologyID
        self.nodeID = nodeID
        self.sessionName = sessionName
        self.sessionID = sessionID
        self.paneID = paneID
        self.serverPID = server?.pid
        self.serverStartTime = server?.startTime
        self.generation = generation
        self.payload = payload
        self.detail = detail
        self.previousAttemptID = previousAttemptID
    }

    /// Whether this entry was recorded for exactly the terminal a delivery is
    /// about to go to. A relaunched pane is a different recipient.
    public func matches(_ target: AgentRuntime.DeliveryTarget) -> Bool {
        sessionID == target.sessionID
            && paneID == target.paneID
            && serverPID == target.server.pid
            && serverStartTime == target.server.startTime
            && generation == target.generation
    }

    /// True for an entry the user may still want to do something about.
    public var needsAttention: Bool {
        status == .uncertain || status == .prepared || status == .failed || status == .sending
    }
}

public enum JournalError: Error, CustomStringConvertible {
    case unreadable(url: URL, detail: String)
    case corrupted(url: URL, detail: String)
    case writeFailed(url: URL, detail: String)

    public var description: String {
        switch self {
        case .unreadable(let url, let detail):
            return "Could not read \(url.lastPathComponent): \(detail)"
        case .corrupted(let url, let detail):
            return "\(url.lastPathComponent) is not a readable message history: \(detail)"
        case .writeFailed(let url, let detail):
            return "Could not write \(url.lastPathComponent): \(detail)"
        }
    }
}

/// Everything Marmy has said to an agent, kept on disk.
///
/// A message is written here *before* it is dispatched. If the write fails,
/// nothing is sent: an agent being told something Marmy has no record of is
/// worse than a message that did not go.
public actor MessageJournal {
    public static let fileName = "messages.json"

    public let fileURL: URL
    private var entries: [JournalEntry] = []
    private var isLoaded = false

    public init(directoryURL: URL) {
        self.fileURL = directoryURL.appendingPathComponent(Self.fileName)
    }

    public func load() throws -> [JournalEntry] {
        if isLoaded { return entries }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            isLoaded = true
            return []
        } catch {
            throw JournalError.unreadable(url: fileURL, detail: error.localizedDescription)
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = try decoder.decode([JournalEntry].self, from: data)
            isLoaded = true
            return entries
        } catch {
            throw JournalError.corrupted(url: fileURL, detail: "\(error)")
        }
    }

    public func all() throws -> [JournalEntry] {
        try load()
    }

    /// One entry as it stands on disk, by id.
    public func entry(id: UUID) throws -> JournalEntry? {
        try load().first { $0.id == id }
    }

    public func entries(forNode nodeID: UUID) throws -> [JournalEntry] {
        try load().filter { $0.nodeID == nodeID }.sorted { $0.createdAt < $1.createdAt }
    }

    /// Writes an entry down. Throws if it could not be stored, so the caller can
    /// refuse to send something it cannot account for.
    @discardableResult
    public func record(_ entry: JournalEntry) throws -> JournalEntry {
        _ = try load()
        // Written to disk before it is believed: a failed write must not leave
        // the app showing a message it cannot account for. Nothing is ever
        // dropped to make room — this history is the point.
        var candidate = entries
        candidate.append(entry)
        try persist(candidate)
        entries = candidate
        return entry
    }

    /// Records what became of an entry. Only ever its own status and detail.
    @discardableResult
    public func update(
        _ id: UUID,
        status: JournalEntry.Status,
        detail: String? = nil,
        now: Date = Date()
    ) throws -> JournalEntry? {
        _ = try load()
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        var candidate = entries
        candidate[index].status = status
        candidate[index].detail = detail
        candidate[index].updatedAt = now
        try persist(candidate)
        entries = candidate
        return candidate[index]
    }

    /// Records where a message went and what became of it, in one write.
    ///
    /// Status and destination belong together: an entry that says "delivered"
    /// but names no recipient is not a record of anything.
    @discardableResult
    public func finish(
        _ id: UUID,
        status: JournalEntry.Status,
        detail: String? = nil,
        sessionID: String? = nil,
        paneID: String? = nil,
        server: TmuxServerIdentity? = nil,
        generation: UUID? = nil,
        now: Date = Date()
    ) throws -> JournalEntry? {
        _ = try load()
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        var candidate = entries
        candidate[index].status = status
        candidate[index].detail = detail
        if let sessionID { candidate[index].sessionID = sessionID }
        if let paneID { candidate[index].paneID = paneID }
        if let server {
            candidate[index].serverPID = server.pid
            candidate[index].serverStartTime = server.startTime
        }
        if let generation { candidate[index].generation = generation }
        candidate[index].updatedAt = now
        try persist(candidate)
        entries = candidate
        return candidate[index]
    }

    /// Entries a previous run left in the air.
    ///
    /// Anything caught mid-send becomes uncertain: it may have reached the
    /// agent, so it is never sent again on Marmy's own initiative.
    @discardableResult
    public func reconcileAfterRestart(now: Date = Date()) throws -> [JournalEntry] {
        _ = try load()
        var candidate = entries
        var changed = false
        for index in candidate.indices where candidate[index].status == .sending {
            candidate[index].status = .uncertain
            candidate[index].detail = "Marmy stopped while this was being sent, so it is not known "
                + "whether the agent received it."
            candidate[index].updatedAt = now
            changed = true
        }
        if changed {
            try persist(candidate)
            entries = candidate
        }
        return candidate.filter { $0.status == .uncertain || $0.status == .prepared }
    }

    /// Entries waiting to be sent, oldest first.
    public func pending() throws -> [JournalEntry] {
        try load().filter { $0.status == .prepared }.sorted { $0.createdAt < $1.createdAt }
    }

    /// Writes a candidate list. Only the caller installs it, and only if this
    /// returns.
    private func persist(_ candidate: [JournalEntry]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let fileManager = FileManager.default
        do {
            let directory = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try encoder.encode(candidate).write(to: fileURL, options: [.atomic])
            // These entries hold whole prompts; nobody else on the machine reads
            // them.
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            throw JournalError.writeFailed(url: fileURL, detail: error.localizedDescription)
        }
    }
}
