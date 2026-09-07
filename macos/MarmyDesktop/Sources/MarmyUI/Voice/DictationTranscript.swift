import Foundation

/// What has been heard so far in one dictation.
///
/// Recognition arrives in two kinds: stretches the recogniser has committed to,
/// each covering a known slice of audio, and a working hypothesis for whatever
/// it has heard since. Committed stretches are kept exactly as they came and are
/// never rewritten by later results; only the hypothesis is replaced.
///
/// That is what makes a five-minute dictation survive: the opening sentence is
/// finished audio, not part of a string that a later, shorter guess could
/// overwrite.
public struct DictationTranscript: Equatable, Sendable {

    /// A committed stretch of speech, anchored to the audio it covers.
    public struct Segment: Equatable, Sendable {
        public var start: Double
        public var duration: Double
        public var text: String

        public init(start: Double, duration: Double, text: String) {
            self.start = start
            self.duration = duration
            self.text = text
        }

        public var end: Double { start + duration }
    }

    /// Two ranges are the same stretch when they begin at the same moment. The
    /// tolerance is far below anything speech timing produces and far above
    /// floating-point noise.
    private static let sameStartTolerance = 1e-6

    public private(set) var segments: [Segment] = []
    /// The recogniser's current guess, and the audio it covers. Replaced as it
    /// changes, and dropped once that audio has been committed.
    public private(set) var hypothesisSegment: Segment?

    public var hypothesis: String { hypothesisSegment?.text ?? "" }

    public init() {}

    /// Everything heard, in the order it was said.
    public var text: String {
        var parts = segments.map(\.text)
        if let hypothesis = hypothesisSegment, !hypothesis.text.trimmed.isEmpty {
            parts.append(hypothesis.text)
        }
        return parts
            .map(\.trimmed)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Committed text only — what survives an interruption.
    public var committedText: String {
        segments.map(\.text.trimmed).filter { !$0.isEmpty }.joined(separator: " ")
    }

    public var isEmpty: Bool { text.isEmpty }

    /// Where the committed audio reaches.
    public var committedEnd: Double {
        segments.map(\.end).max() ?? 0
    }

    public mutating func apply(_ event: SpeechEvent) {
        switch event {
        case .volatile(let text, let start, let duration):
            let trimmed = text.trimmed
            guard !trimmed.isEmpty else {
                hypothesisSegment = nil
                return
            }
            let guess = Segment(start: start, duration: duration, text: trimmed)
            // A guess at audio that has already been committed is stale — it
            // would print the same words a second time.
            guard !isAlreadyCommitted(guess) else { return }
            hypothesisSegment = guess
        case .finalized(let text, let start, let duration):
            commit(text: text, start: start, duration: duration)
        case .failed, .finished, .notice, .listening:
            break
        }
    }

    /// Commits a stretch of speech.
    ///
    /// A stretch beginning where an existing one does replaces it — the
    /// recogniser has improved its answer for that audio. A stretch that covers
    /// existing ones replaces them rather than being appended alongside, so the
    /// same words never appear twice. The working guess is dropped only when the
    /// committed audio actually overlaps the audio it was guessing at; a late
    /// result for older speech leaves the tail alone.
    public mutating func commit(text: String, start: Double, duration: Double = 0) {
        let trimmed = text.trimmed
        let range = Segment(start: start, duration: duration, text: trimmed)

        if let index = segments.firstIndex(where: { abs($0.start - start) <= Self.sameStartTolerance }) {
            if trimmed.isEmpty {
                segments.remove(at: index)
            } else {
                segments[index].text = trimmed
                segments[index].duration = max(duration, segments[index].duration)
                // A longer answer for the same audio swallows the stretches that
                // were inside it, rather than leaving them to be said twice.
                let updated = segments[index]
                let inside = segments.filter { segment in
                    abs(segment.start - updated.start) > Self.sameStartTolerance
                        && covered(segment, by: updated)
                }
                segments.removeAll { segment in
                    inside.contains { abs($0.start - segment.start) <= Self.sameStartTolerance }
                }
            }
        } else if !trimmed.isEmpty {
            let swallowed = segments.filter { covered($0, by: range) }
            segments.removeAll { segment in
                swallowed.contains { abs($0.start - segment.start) <= Self.sameStartTolerance }
            }
            if let index = segments.firstIndex(where: { $0.start > start }) {
                segments.insert(range, at: index)
            } else {
                segments.append(range)
            }
        }

        if let hypothesis = hypothesisSegment, overlaps(range, hypothesis) {
            hypothesisSegment = nil
        }
    }

    /// Keeps the current guess as committed text.
    ///
    /// Used when a capture ends before the recogniser commits its tail: those
    /// words were said, so they are kept, at the place in the audio they were
    /// actually spoken.
    public mutating func commitHypothesis() {
        guard let hypothesis = hypothesisSegment, !hypothesis.text.trimmed.isEmpty else { return }
        hypothesisSegment = nil
        // Never on top of committed audio: if the guess claims a range that has
        // already been committed, it goes after it instead.
        let start = max(hypothesis.start, committedEnd + Self.sameStartTolerance)
        segments.append(Segment(start: start, duration: hypothesis.duration, text: hypothesis.text.trimmed))
        segments.sort { $0.start < $1.start }
    }

    /// True when `segment` lies wholly inside `range`. Ranges are half-open:
    /// `[start, end)`, so one ending exactly where another begins is next to it,
    /// not inside it.
    private func covered(_ segment: Segment, by range: Segment) -> Bool {
        guard range.duration > 0 else { return false }
        let segmentEnd = segment.duration > 0 ? segment.end : segment.start
        return segment.start >= range.start - Self.sameStartTolerance
            && segmentEnd <= range.end + Self.sameStartTolerance
    }

    /// True when two half-open ranges share any audio. Touching is not sharing:
    /// a stretch ending at 3 and one beginning at 3 are neighbours.
    private func overlaps(_ a: Segment, _ b: Segment) -> Bool {
        let tolerance = Self.sameStartTolerance
        if a.duration <= 0 {
            let bEnd = b.duration > 0 ? b.end : b.start
            return a.start >= b.start - tolerance && a.start < bEnd - tolerance
        }
        if b.duration <= 0 {
            return b.start >= a.start - tolerance && b.start < a.end - tolerance
        }
        return a.start + tolerance < b.end && b.start + tolerance < a.end
    }

    /// True when this guess covers audio that has already been committed.
    private func isAlreadyCommitted(_ guess: Segment) -> Bool {
        let guessEnd = guess.duration > 0 ? guess.end : guess.start
        return guessEnd <= committedEnd + Self.sameStartTolerance && committedEnd > 0
    }
}

extension String {
    /// Trims spaces and tabs but keeps line breaks: a dictated paragraph break
    /// is something the speaker asked for.
    var trimmed: String {
        trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
    }
}
