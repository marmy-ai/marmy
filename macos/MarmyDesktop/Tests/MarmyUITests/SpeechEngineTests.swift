import AVFoundation
import XCTest
@testable import MarmyUI

/// A stand-in microphone. Nothing here opens a real one.
@MainActor
final class FakeMicrophone: MicrophoneCapturing {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var lastTargetFormat: AVAudioFormat?
    private var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    var failure: Error?
    var isRunning = false

    func start(
        targetFormat: AVAudioFormat?,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onFailure: @escaping @Sendable (BufferConverter.Failure) -> Void
    ) throws {
        if let failure { throw failure }
        startCount += 1
        lastTargetFormat = targetFormat
        self.onBuffer = onBuffer
        isRunning = true
    }

    func stop() {
        if isRunning { stopCount += 1 }
        isRunning = false
        onBuffer = nil
    }
}

/// What the engines guarantee before a microphone is ever opened.
@MainActor
final class SpeechEngineTests: XCTestCase {

    func testReleasingBeforePreparationFinishesNeverOpensTheMicrophone() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("the long-form engine needs macOS 26") }
        let microphone = FakeMicrophone()
        let engine = ModernSpeechEngine(locale: Locale(identifier: "en_US"), capture: microphone)

        try engine.start { _ in }
        // The hold ends while the analyzer's format is still being worked out.
        engine.cancel()
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(microphone.startCount, 0, "the microphone must not open after the user let go")
    }

    func testTheMicrophoneOnlyOpensOnceTheFormatIsKnown() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("the long-form engine needs macOS 26") }
        let microphone = FakeMicrophone()
        let engine = ModernSpeechEngine(locale: Locale(identifier: "en_US"), capture: microphone)
        await engine.awaitCapabilities()
        try XCTSkipUnless(engine.isAvailable, "en_US transcription is not available here")
        try XCTSkipUnless(engine.preparation.isReady, "the speech model is not installed")

        try engine.start { _ in }
        try await Task.sleep(for: .milliseconds(600))
        engine.cancel()

        XCTAssertEqual(microphone.startCount, 1)
        XCTAssertNotNil(microphone.lastTargetFormat, "the converter was ready before any audio arrived")
    }

    func testReleasingDuringStartupNeverOpensTheMicrophoneLater() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("the long-form engine needs macOS 26") }
        let microphone = FakeMicrophone()
        let engine = ModernSpeechEngine(locale: Locale(identifier: "en_US"), capture: microphone)

        var events: [SpeechEvent] = []
        try engine.start { events.append($0) }
        // Let go while the analyzer's format is still being negotiated. This is
        // the ordinary case of a quick hold, not a cancel.
        engine.stop()
        try await Task.sleep(for: .milliseconds(600))

        XCTAssertEqual(microphone.startCount, 0, "the microphone must not open after the user let go")
        XCTAssertTrue(events.contains(.finished), "and the capture is reported as over")
    }

    func testANewHoldAfterACancelledOneStartsCleanly() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("the long-form engine needs macOS 26") }
        let microphone = FakeMicrophone()
        let engine = ModernSpeechEngine(locale: Locale(identifier: "en_US"), capture: microphone)
        await engine.awaitCapabilities()
        try XCTSkipUnless(engine.isAvailable && engine.preparation.isReady, "no speech model here")

        try engine.start { _ in }
        engine.cancel()
        try engine.start { _ in }
        try await Task.sleep(for: .milliseconds(700))
        engine.cancel()

        XCTAssertEqual(microphone.startCount, 1, "only the hold that is still wanted opens the microphone")
    }

    func testTheEngineSaysWhenTheMicrophoneIsActuallyOpen() throws {
        let microphone = FakeMicrophone()
        let engine = LegacySpeechEngine(locale: Locale(identifier: "en_US"), capture: microphone)
        try XCTSkipUnless(engine.isAvailable, "no recogniser for this language")

        var events: [SpeechEvent] = []
        try engine.start { events.append($0) }
        defer { engine.cancel() }

        XCTAssertTrue(events.contains(.listening), "the UI can stop saying 'starting' now")
        XCTAssertEqual(microphone.startCount, 1)
    }

    func testTheModernEngineDoesNotRequireTheOlderSpeechPermission() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("the long-form engine needs macOS 26") }
        let engine = ModernSpeechEngine(locale: Locale(identifier: "en_US"), capture: FakeMicrophone())

        // It transcribes on this Mac, so the microphone is the only thing it
        // needs; asking for the old service's permission would be noise.
        XCTAssertEqual(engine.speechAuthorization, .authorized)
        XCTAssertEqual(engine.authorization, engine.microphoneAuthorization)
    }

    func testCapabilitiesStartOutAsCheckingRatherThanUnavailable() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("the long-form engine needs macOS 26") }
        let engine = ModernSpeechEngine(locale: Locale(identifier: "en_US"), capture: FakeMicrophone())

        XCTAssertEqual(engine.preparation, .checking, "a first hold must not fail while this is unknown")
    }

    func testALegacyEngineReportsItselfAsShortForm() {
        let engine = LegacySpeechEngine(locale: Locale(identifier: "en_US"), capture: FakeMicrophone())
        XCTAssertFalse(engine.supportsLongForm)
    }

    func testAMicrophoneThatCannotStartIsReported() throws {
        let microphone = FakeMicrophone()
        microphone.failure = AudioCaptureError.noInput
        let engine = LegacySpeechEngine(locale: Locale(identifier: "en_US"), capture: microphone)

        var events: [SpeechEvent] = []
        try engine.start { events.append($0) }

        XCTAssertTrue(events.contains { event in
            if case .failed = event { return true } else { return false }
        }, "a microphone that will not open is said out loud")
    }
}
