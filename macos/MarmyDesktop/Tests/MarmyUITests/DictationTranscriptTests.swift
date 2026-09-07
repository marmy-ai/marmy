import XCTest
@testable import MarmyUI

/// How a long dictation is assembled from what the recogniser reports.
final class DictationTranscriptTests: XCTestCase {

    func testCommittedStretchesAreKeptAndTheGuessIsReplaced() {
        var transcript = DictationTranscript()
        transcript.apply(.finalized(text: "the first thing", start: 0, duration: 2))
        transcript.apply(.volatile(text: "and the second", start: 2, duration: 1))
        transcript.apply(.volatile(text: "and the second thing", start: 2, duration: 2))

        XCTAssertEqual(transcript.text, "the first thing and the second thing")
        XCTAssertEqual(transcript.committedText, "the first thing")
    }

    func testAFiveMinuteDictationKeepsEveryStretch() {
        var transcript = DictationTranscript()
        var expected: [String] = []
        for index in 0..<60 {
            let text = "stretch \(index)"
            expected.append(text)
            transcript.apply(.volatile(text: "\(text) roughly", start: Double(index) * 5, duration: 5))
            transcript.apply(.finalized(text: text, start: Double(index) * 5, duration: 5))
        }

        XCTAssertEqual(transcript.text, expected.joined(separator: " "))
        XCTAssertTrue(transcript.text.hasPrefix("stretch 0 "))
    }

    func testARevisionReplacesOnlyItsOwnStretch() {
        var transcript = DictationTranscript()
        transcript.apply(.finalized(text: "recognise speech", start: 0, duration: 3))
        transcript.apply(.finalized(text: "wreck a nice beach", start: 3, duration: 3))
        transcript.apply(.finalized(text: "recognise speech now", start: 0, duration: 3))

        XCTAssertEqual(transcript.text, "recognise speech now wreck a nice beach")
    }

    func testAShorterRevisionDoesNotShortenEverythingElse() {
        // The failure this whole design exists to prevent: a later, shorter
        // hypothesis must never replace what came before it.
        var transcript = DictationTranscript()
        transcript.apply(.finalized(text: "a long opening sentence that took a while", start: 0, duration: 8))
        transcript.apply(.volatile(text: "um", start: 8, duration: 1))

        XCTAssertTrue(transcript.text.hasPrefix("a long opening sentence"))
        XCTAssertTrue(transcript.text.hasSuffix("um"))
    }

    func testOutOfOrderStretchesAreSortedByWhenTheyWereSpoken() {
        var transcript = DictationTranscript()
        transcript.apply(.finalized(text: "third", start: 20, duration: 2))
        transcript.apply(.finalized(text: "first", start: 0, duration: 2))
        transcript.apply(.finalized(text: "second", start: 10, duration: 2))

        XCTAssertEqual(transcript.text, "first second third")
        XCTAssertEqual(transcript.segments.map(\.start), [0, 10, 20])
    }

    func testAnEmptyRevisionRemovesTheStretch() {
        var transcript = DictationTranscript()
        transcript.apply(.finalized(text: "mistake", start: 4, duration: 1))
        transcript.apply(.finalized(text: "kept", start: 0, duration: 1))
        transcript.apply(.finalized(text: "   ", start: 4, duration: 1))

        XCTAssertEqual(transcript.text, "kept")
    }

    func testSilenceLeavesTheTranscriptAlone() {
        var transcript = DictationTranscript()
        transcript.apply(.finalized(text: "before", start: 0, duration: 2))
        transcript.apply(.volatile(text: "", start: 2, duration: 1))

        XCTAssertEqual(transcript.text, "before")
    }

    func testAnUncommittedTailCanBeKept() {
        var transcript = DictationTranscript()
        transcript.apply(.finalized(text: "committed", start: 0, duration: 2))
        transcript.apply(.volatile(text: "still being said", start: 2, duration: 3))
        transcript.commitHypothesis()

        XCTAssertEqual(transcript.text, "committed still being said")
        XCTAssertEqual(transcript.committedText, "committed still being said",
                       "it survives an interruption now")
    }

    func testAKeptTailNeverReplacesTheStretchBeforeIt() {
        // The arithmetic trap: a tail placed just after a segment that starts at
        // a round number used to land within matching distance of it and
        // overwrite it.
        var transcript = DictationTranscript()
        transcript.apply(.finalized(text: "the committed sentence", start: 1.0, duration: 0))
        transcript.apply(.volatile(text: "and the tail", start: 1.0, duration: 2))
        transcript.commitHypothesis()

        XCTAssertEqual(transcript.segments.count, 2, "two stretches, not one overwritten")
        XCTAssertEqual(transcript.text, "the committed sentence and the tail")
    }

    func testAKeptTailSurvivesAnyStartTime() {
        for start in [0.0, 0.5, 1.0, 42.0, 123.456] {
            var transcript = DictationTranscript()
            transcript.apply(.finalized(text: "committed", start: start, duration: 1))
            transcript.apply(.volatile(text: "tail", start: start + 1, duration: 1))
            transcript.commitHypothesis()
            XCTAssertEqual(transcript.text, "committed tail", "start=\(start)")
        }
    }

    func testALateResultForOlderAudioLeavesTheCurrentGuessAlone() {
        var transcript = DictationTranscript()
        transcript.apply(.finalized(text: "first", start: 0, duration: 5))
        transcript.apply(.finalized(text: "second", start: 5, duration: 5))
        transcript.apply(.volatile(text: "what is being said now", start: 10, duration: 4))
        // A revision of the *first* stretch arrives late.
        transcript.apply(.finalized(text: "first, corrected", start: 0, duration: 5))

        XCTAssertEqual(
            transcript.text, "first, corrected second what is being said now",
            "the tail the user is still speaking is not thrown away")
    }

    func testCommittingTheTailClearsTheGuessItCovered() {
        var transcript = DictationTranscript()
        transcript.apply(.volatile(text: "still speaking", start: 0, duration: 2))
        transcript.apply(.finalized(text: "still speaking now", start: 0, duration: 3))

        XCTAssertEqual(transcript.text, "still speaking now", "no duplicated tail")
    }

    func testLineBreaksInDictationAreKept() {
        var transcript = DictationTranscript()
        transcript.apply(.finalized(text: "first line\nsecond line", start: 0, duration: 2))

        XCTAssertEqual(transcript.text, "first line\nsecond line")
    }

    func testDurationsAreRemembered() {
        var transcript = DictationTranscript()
        transcript.apply(.finalized(text: "a stretch", start: 4, duration: 6))

        XCTAssertEqual(transcript.segments.first?.end, 10)
        XCTAssertEqual(transcript.committedEnd, 10)
    }

    func testANoticeChangesNothing() {
        var transcript = DictationTranscript()
        transcript.apply(.finalized(text: "kept", start: 0, duration: 1))
        transcript.apply(.notice("rolled over"))

        XCTAssertEqual(transcript.text, "kept")
    }

    func testAStretchEndingWhereTheNextBeginsDoesNotEraseIt() {
        // Ranges are half-open: [0,3) and [3,5) are neighbours, not overlaps.
        var transcript = DictationTranscript()
        transcript.apply(.finalized(text: "first part", start: 0, duration: 3))
        transcript.apply(.volatile(text: "second part", start: 3, duration: 2))
        // A revision of the first stretch must leave the tail alone.
        transcript.apply(.finalized(text: "first part revised", start: 0, duration: 3))

        XCTAssertEqual(transcript.text, "first part revised second part")
    }

    func testAWiderAnswerForTheSameAudioSwallowsWhatWasInsideIt() {
        var transcript = DictationTranscript()
        transcript.apply(.finalized(text: "one", start: 0, duration: 1))
        transcript.apply(.finalized(text: "two", start: 1, duration: 1))
        // The recogniser comes back with one answer covering both.
        transcript.apply(.finalized(text: "one two", start: 0, duration: 2))

        XCTAssertEqual(transcript.text, "one two", "not \"one two two\"")
        XCTAssertEqual(transcript.segments.count, 1)
    }

    func testAStaleGuessAtAlreadyCommittedAudioIsIgnored() {
        var transcript = DictationTranscript()
        transcript.apply(.volatile(text: "the opening", start: 0, duration: 3))
        transcript.apply(.finalized(text: "the opening line", start: 0, duration: 3))
        // A guess for that same audio arrives after it was committed.
        transcript.apply(.volatile(text: "the opening", start: 0, duration: 3))

        XCTAssertEqual(transcript.text, "the opening line", "the opening is not printed twice")
    }

    func testCommittingNothingIsHarmless() {
        var transcript = DictationTranscript()
        transcript.commitHypothesis()
        XCTAssertTrue(transcript.isEmpty)

        transcript.apply(.finished)
        transcript.apply(.failed(.noAudioInput))
        XCTAssertTrue(transcript.isEmpty)
    }

    func testTheShortFormRecogniserContributesOneStretch() {
        // That recogniser reports one cumulative string and then stops. What it
        // heard is committed as a single stretch; nothing pretends there is more.
        var transcript = DictationTranscript()
        transcript.apply(.volatile(text: "first minute of", start: 0, duration: 40))
        transcript.apply(.volatile(text: "first minute of talking", start: 0, duration: 55))
        transcript.apply(.finalized(text: "first minute of talking", start: 0, duration: 60))

        XCTAssertEqual(transcript.text, "first minute of talking")
        XCTAssertEqual(transcript.segments.count, 1, "no duplicated tail")
    }
}
