import Foundation
import XCTest
@testable import MarmyUI

/// The production speech adapter against a real recording, minutes long.
///
/// Opt in with `MARMY_RUN_SPEECH_TESTS=1`; point `MARMY_SPEECH_FIXTURE` at an
/// audio file. It reads a file rather than a microphone, so it asks for no
/// permissions and records nothing.
@MainActor
final class LongDictationFixtureTests: XCTestCase {

    private var fixture: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MARMY_RUN_SPEECH_TESTS"] == "1",
            "set MARMY_RUN_SPEECH_TESTS=1 to transcribe the long-dictation fixture")
        guard #available(macOS 26.0, *) else { throw XCTSkip("the long-form engine needs macOS 26") }

        let path = ProcessInfo.processInfo.environment["MARMY_SPEECH_FIXTURE"]
            ?? "/tmp/marmy-long-dictation-fixture.aiff"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("no fixture at \(path)")
        }
        fixture = URL(fileURLWithPath: path)
    }

    func testTheAdapterKeepsTheWholeOfALongDictation() async throws {
        guard #available(macOS 26.0, *) else { return }
        let engine = ModernSpeechEngine(locale: Locale(identifier: "en_US"))
        await engine.awaitCapabilities()
        try XCTSkipUnless(engine.isAvailable, "en_US is not supported for transcription here")
        if engine.preparation == .needsInstallation {
            try await engine.prepare()
        }
        try XCTSkipUnless(engine.preparation.isReady, "the speech model is not installed")

        // Exactly what the live path does with what the recogniser reports.
        let events = try await engine.transcribe(file: fixture)
        var transcript = DictationTranscript()
        for event in events {
            transcript.apply(event)
        }
        transcript.commitHypothesis()

        let finalized = events.filter {
            if case .finalized = $0 { return true } else { return false }
        }
        let text = transcript.text.lowercased()

        XCTAssertGreaterThan(finalized.count, 20, "a long recording commits many stretches")
        XCTAssertGreaterThan(text.split(whereSeparator: \.isWhitespace).count, 200)
        XCTAssertTrue(text.contains("blue elephant"), "the opening marker survived the whole capture")
        XCTAssertTrue(text.contains("purple telescope"), "and so did the closing one")

        // The opening really is at the start, not merely present.
        let openingPosition = try XCTUnwrap(text.range(of: "blue elephant")).lowerBound
        let closingPosition = try XCTUnwrap(text.range(of: "purple telescope")).lowerBound
        XCTAssertLessThan(openingPosition, closingPosition)
        XCTAssertLessThan(
            text.distance(from: text.startIndex, to: openingPosition), 200,
            "the first words are still the first words")
    }
}
