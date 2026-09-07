import Foundation
import MarmyCore
import MarmyRuntime
import Observation

/// A dictation that has been spoken but not yet put into its agent's prompt.
///
/// It exists so words are never lost between "you stopped talking" and "the text
/// is in the terminal". Each capture is its own item, identified by the capture
/// it came from: a second dictation never overwrites the first, and a late
/// result can only ever change the capture it belongs to.
public struct PendingDictation: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case pasting
        case failed(String)
        /// It may or may not have reached the prompt. Only the user can tell,
        /// by looking, so Marmy will not try again on its own.
        case uncertain(String)
    }

    /// The capture these words came from.
    public let id: UUID
    public var target: WorkTarget
    public var text: String
    /// What the terminal looked like when the words were spoken.
    public var identity: TerminalIdentity
    public var clientPID: Int32?
    public var state: State
    public var spokenAt: Date

    public init(
        id: UUID,
        target: WorkTarget,
        text: String,
        identity: TerminalIdentity,
        clientPID: Int32?,
        state: State,
        spokenAt: Date
    ) {
        self.id = id
        self.target = target
        self.text = text
        self.identity = identity
        self.clientPID = clientPID
        self.state = state
        self.spokenAt = spokenAt
    }

    public var isResolved: Bool { false }
}

/// Everything spoken and waiting, by capture.
@MainActor
@Observable
public final class DictationDeliveryQueue {
    public private(set) var pending: [UUID: PendingDictation] = [:]

    public init() {}

    /// Captures waiting for this agent, oldest first.
    public func items(for target: WorkTarget) -> [PendingDictation] {
        pending.values.filter { $0.target == target }.sorted { $0.spokenAt < $1.spokenAt }
    }

    /// The one to show: the oldest thing still waiting.
    public func item(for target: WorkTarget) -> PendingDictation? {
        items(for: target).first
    }

    public func item(id: UUID) -> PendingDictation? { pending[id] }

    public func hold(_ item: PendingDictation) {
        pending[item.id] = item
    }

    /// Only ever the exact capture: never "whatever is waiting for this agent".
    public func markFailed(_ captureID: UUID, reason: String) {
        pending[captureID]?.state = .failed(reason)
    }

    public func markUncertain(_ captureID: UUID, reason: String) {
        pending[captureID]?.state = .uncertain(reason)
    }

    public func markPasting(_ captureID: UUID) {
        pending[captureID]?.state = .pasting
    }

    @discardableResult
    public func discard(_ captureID: UUID) -> PendingDictation? {
        pending.removeValue(forKey: captureID)
    }

    /// True when this agent has words the user has not dealt with yet.
    public func hasUnresolved(for target: WorkTarget) -> Bool {
        !items(for: target).isEmpty
    }

    public var hasAnything: Bool { !pending.isEmpty }
}
