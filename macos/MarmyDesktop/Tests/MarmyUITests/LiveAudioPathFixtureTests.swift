import AVFoundation
import Foundation
import XCTest
@testable import MarmyUI

/// The live dictation path — conversion, feeding, analyzer — over a real
/// recording that runs for minutes.
///
/// Opt in with `MARMY_RUN_SPEECH_TESTS=1`. Audio comes from a file, so nothing
/// asks for the microphone; what it exercises is the same converter and the same
/// input stream a hold uses.
@MainActor
final class LiveAudioPathFixtureTests: XCTestCase {

    private var fixture: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MARMY_RUN_SPEECH_TESTS"] == "1",
            "set MARMY_RUN_SPEECH_TESTS=1 to run the long-dictation fixture")
        guard #available(macOS 26.0, *) else { throw XCTSkip("the long-form engine needs macOS 26") }

        let path = ProcessInfo.processInfo.environment["MARMY_SPEECH_FIXTURE"]
            ?? "/tmp/marmy-long-dictation-fixture.aiff"
        guard FileManager.default.fileExists(atPath: path) else { throw XCTSkip("no fixture at \(path)") }
        fixture = URL(fileURLWithPath: path)
    }

    /// The recording, in the chunks a microphone tap would hand over.
    private func readBuffers(chunkFrames: AVAudioFrameCount = 4096) throws -> ([AVAudioPCMBuffer], AVAudioFormat) {
        let file = try AVAudioFile(forReading: fixture)
        let format = file.processingFormat
        var buffers: [AVAudioPCMBuffer] = []
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { break }
            try file.read(into: buffer, frameCount: chunkFrames)
            if buffer.frameLength == 0 { break }
            buffers.append(buffer)
        }
        return (buffers, format)
    }

    func testTheLivePathKeepsTheWholeOfALongDictation() async throws {
        guard #available(macOS 26.0, *) else { return }
        let engine = ModernSpeechEngine(locale: Locale(identifier: "en_US"))
        await engine.awaitCapabilities()
        try XCTSkipUnless(engine.isAvailable, "en_US is not supported for transcription here")
        if engine.preparation == .needsInstallation { try await engine.prepare() }
        try XCTSkipUnless(engine.preparation.isReady, "the speech model is not installed")

        let (buffers, format) = try readBuffers()
        XCTAssertGreaterThan(buffers.count, 100, "several minutes of audio, in tap-sized pieces")

        // Exactly what a hold does with what the tap produces.
        let events = try await engine.transcribe(buffers: buffers, sourceFormat: format)
        var transcript = DictationTranscript()
        for event in events { transcript.apply(event) }
        transcript.commitHypothesis()

        let text = transcript.text.lowercased()
        let finalized = events.filter { if case .finalized = $0 { return true } else { return false } }

        XCTAssertGreaterThan(finalized.count, 20, "the recogniser committed many stretches")
        XCTAssertGreaterThan(text.split(whereSeparator: \.isWhitespace).count, 200)
        XCTAssertTrue(text.contains("blue elephant"), "the opening survived conversion and feeding")
        XCTAssertTrue(text.contains("purple telescope"), "and so did the close")

        let opening = try XCTUnwrap(text.range(of: "blue elephant")).lowerBound
        XCTAssertLessThan(
            text.distance(from: text.startIndex, to: opening), 200,
            "the first words are still the first words")
    }
}
