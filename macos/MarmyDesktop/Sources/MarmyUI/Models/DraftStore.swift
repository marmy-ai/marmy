import Foundation

/// Per-agent message drafts.
///
/// Drafts are kept per target and survive switching agents, teams, and modes, so
/// text typed for one agent can never be sent to another. Dictation writes
/// through `applyDictation`, which replaces only the dictated tail of a draft
/// rather than appending every partial hypothesis.
@MainActor
@Observable
public final class DraftStore {
    private var texts: [WorkTarget: String] = [:]
    /// While dictation is running: the draft as it was when the hold started.
    private var dictationBases: [WorkTarget: String] = [:]

    public init() {}

    public subscript(target: WorkTarget) -> String {
        get { texts[target] ?? "" }
        set { texts[target] = newValue }
    }

    public func text(for target: WorkTarget) -> String {
        texts[target] ?? ""
    }

    public func setText(_ text: String, for target: WorkTarget) {
        texts[target] = text
    }

    public func isEmpty(_ target: WorkTarget) -> Bool {
        text(for: target).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Records where a dictation started so partial results replace each other.
    public func beginDictation(on target: WorkTarget) {
        dictationBases[target] = text(for: target)
    }

    /// Applies the latest transcript for a running dictation.
    ///
    /// The transcript always replaces the previous one, so a stream of partial
    /// results reads as one growing sentence instead of repeating itself.
    public func applyDictation(_ transcript: String, to target: WorkTarget) {
        let base = dictationBases[target] ?? text(for: target)
        dictationBases[target] = base
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            texts[target] = base
            return
        }
        if base.isEmpty {
            texts[target] = trimmed
        } else if base.hasSuffix(" ") || base.hasSuffix("\n") {
            texts[target] = base + trimmed
        } else {
            texts[target] = base + " " + trimmed
        }
    }

    /// Ends a dictation, leaving whatever it produced in the draft.
    public func endDictation(on target: WorkTarget) {
        dictationBases.removeValue(forKey: target)
    }

    /// Throws away what a dictation added and restores the draft as typed.
    public func revertDictation(on target: WorkTarget) {
        if let base = dictationBases.removeValue(forKey: target) {
            texts[target] = base
        }
    }

    public func isDictating(_ target: WorkTarget) -> Bool {
        dictationBases[target] != nil
    }

    /// Clears a draft only if it still holds exactly what was sent, so anything
    /// typed while the send was in flight is kept.
    @discardableResult
    public func clearIfUnchanged(_ sent: String, for target: WorkTarget) -> Bool {
        guard text(for: target) == sent else { return false }
        texts[target] = ""
        return true
    }

    public func forget(_ target: WorkTarget) {
        texts.removeValue(forKey: target)
        dictationBases.removeValue(forKey: target)
    }
}
