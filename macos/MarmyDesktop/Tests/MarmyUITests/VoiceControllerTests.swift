import XCTest
import MarmyCore
@testable import MarmyUI

/// The hold-to-talk state machine, driven entirely by scripted speech events.
/// No microphone is opened and no permission is ever requested from macOS.
@MainActor
final class VoiceControllerTests: XCTestCase {

    private var engine: ScriptedSpeechEngine!
    private var voice: VoiceController!
    /// What the controller handed over, per agent, as the app would receive it.
    private var delivered: [WorkTarget: String] = [:]
    private let alice = WorkTarget.node(UUID(uuidString: "00000000-0000-4000-8000-000000000001")!)
    private let bob = WorkTarget.node(UUID(uuidString: "00000000-0000-4000-8000-000000000002")!)

    override func setUp() {
        engine = ScriptedSpeechEngine()
        voice = VoiceController(engine: engine)
        delivered = [:]
        voice.onFinished = { [weak self] _, target, text, _ in
            self?.delivered[target] = text
        }
    }

    /// What would end up in that agent's prompt: what has been handed over, or
    /// what is being heard right now.
    private func text(for target: WorkTarget) -> String {
        delivered[target] ?? (voice.target == target ? voice.preview : "")
    }

    func testDictationAppendsToTheDraftItStartedOn() {
        voice.beginHold(on: alice)
        engine.emit(.volatile(text: "check", start: 0, duration: 1))
        engine.emit(.volatile(text: "check the build", start: 0, duration: 1))

        XCTAssertEqual(text(for: alice), "check the build",
                       "the working guess replaces itself instead of piling up")

        voice.endHold()
        engine.emit(.finalized(text: "check the build twice", start: 0, duration: 3))
        engine.emit(.finished)

        XCTAssertEqual(text(for: alice), "check the build twice")
        XCTAssertEqual(voice.status, .idle)
        XCTAssertNil(voice.target)
    }

    func testALongDictationKeepsItsOpeningSentence() {
        // Five minutes of speech, committed a stretch at a time. The first
        // sentence must still be there at the end.
        voice.beginHold(on: alice)
        var spoken: [String] = []
        for minute in 0..<5 {
            for chunk in 0..<12 {
                let start = Double(minute * 60 + chunk * 5)
                let text = "sentence \(minute)-\(chunk)"
                spoken.append(text)
                // The recogniser guesses, then commits.
                engine.emit(.volatile(text: text + " maybe", start: start, duration: 5))
                engine.emit(.finalized(text: text, start: start, duration: 5))
            }
        }
        voice.endHold()
        engine.emit(.finished)

        let result = text(for: alice)
        XCTAssertTrue(result.hasPrefix("sentence 0-0"), "the opening is intact: \(result.prefix(40))")
        XCTAssertTrue(result.hasSuffix("sentence 4-11"))
        XCTAssertEqual(result, spoken.joined(separator: " "))
        XCTAssertFalse(result.contains("maybe"), "a superseded guess is gone")
    }

    func testAShorterCorrectionOnlyReplacesTheStretchItCovers() {
        voice.beginHold(on: alice)
        engine.emit(.finalized(text: "the quick brown fox", start: 0, duration: 4))
        engine.emit(.finalized(text: "jumps over the lazy dog", start: 4, duration: 4))
        // The recogniser improves its answer for the first stretch.
        engine.emit(.finalized(text: "the quick brown ox", start: 0, duration: 4))

        XCTAssertEqual(text(for: alice), "the quick brown ox jumps over the lazy dog")
    }

    func testStretchesArriveInTimeOrderEvenIfTheyComeBackOutOfOrder() {
        voice.beginHold(on: alice)
        engine.emit(.finalized(text: "second", start: 10, duration: 2))
        engine.emit(.finalized(text: "first", start: 0, duration: 2))
        engine.emit(.finalized(text: "third", start: 20, duration: 2))

        XCTAssertEqual(text(for: alice), "first second third")
    }

    func testAPauseInSpeechDoesNotEndTheCapture() {
        voice.beginHold(on: alice)
        engine.emit(.finalized(text: "before the pause", start: 0, duration: 3))
        engine.emit(.volatile(text: "", start: 3, duration: 1))          // silence
        engine.emit(.finalized(text: "after the pause", start: 30, duration: 3))

        XCTAssertTrue(voice.isCapturing, "a pause is not the end of a dictation")
        XCTAssertEqual(text(for: alice), "before the pause after the pause")
    }

    func testAnInterruptedCaptureKeepsWhatItHeardAndSaysSo() {
        voice.beginHold(on: alice)
        engine.emit(.finalized(text: "the first minute of talking", start: 0, duration: 60))
        engine.emit(.volatile(text: "and the beginning of the second", start: 60, duration: 5))
        engine.emit(.failed(.interrupted("the recogniser reached its limit.")))

        XCTAssertEqual(
            text(for: alice),
            "the first minute of talking and the beginning of the second",
            "nothing heard is thrown away")
        XCTAssertTrue(voice.wasInterrupted)
        guard case .failed(let message) = voice.status else {
            return XCTFail("expected .failed, got \(voice.status)")
        }
        XCTAssertTrue(message.contains("interrupted"))
        XCTAssertTrue(message.contains("kept"))
    }

    func testTwoAgentsKeepTheirOwnDictations() {
        voice.beginHold(on: alice)
        engine.emit(.finalized(text: "for alice only", start: 0, duration: 2))
        voice.endHold()
        engine.emit(.finished)

        XCTAssertEqual(text(for: alice), "for alice only")
        XCTAssertEqual(text(for: bob), "", "nothing leaked sideways")

        voice.beginHold(on: bob)
        engine.emit(.finalized(text: "for bob only", start: 0, duration: 2))
        voice.endHold()
        engine.emit(.finished)

        XCTAssertEqual(text(for: bob), "for bob only")
        XCTAssertEqual(text(for: alice), "for alice only")
    }

    func testSwitchingAgentsStopsTheCaptureAndKeepsTheWordsWhereTheyWereSpoken() {
        voice.beginHold(on: alice)
        engine.emit(.volatile(text: "for alice", start: 0, duration: 1))
        let retired = engine.captureHandler()

        voice.cancel()
        engine.emitFromRetiredRun(.finalized(text: "for alice, later", start: 5, duration: 2), using: retired)

        XCTAssertEqual(text(for: alice), "for alice")
        XCTAssertTrue(text(for: bob).isEmpty, "a retired transcript reaches nobody else")
        XCTAssertEqual(engine.cancelCount, 1)
    }

    func testALateCallbackFromAnOldRunCannotDisturbANewOne() {
        voice.beginHold(on: alice)
        let firstRun = engine.captureHandler()
        voice.cancel()

        voice.beginHold(on: bob)
        engine.emit(.volatile(text: "bob's message", start: 0, duration: 1))
        engine.emitFromRetiredRun(.finalized(text: "alice's leftovers", start: 5, duration: 2), using: firstRun)

        XCTAssertEqual(text(for: bob), "bob's message")
        XCTAssertEqual(voice.target, bob, "the new capture is still running")
        XCTAssertTrue(voice.isCapturing)
    }

    func testALateGuessAfterTheCaptureFinishedIsIgnored() {
        voice.beginHold(on: alice)
        engine.emit(.volatile(text: "hello", start: 0, duration: 1))
        voice.endHold()
        engine.emit(.finalized(text: "hello there", start: 0, duration: 2))
        engine.emit(.finished)
        engine.emit(.volatile(text: "hello", start: 0, duration: 1))

        XCTAssertEqual(text(for: alice), "hello there", "the finished transcript is not rewritten")
    }

    func testEndingWithAnUncommittedGuessKeepsIt() {
        // The recogniser never committed the tail; those words were still said.
        voice.beginHold(on: alice)
        engine.emit(.volatile(text: "ship the fix", start: 0, duration: 1))
        voice.endHold()
        engine.emit(.finished)

        XCTAssertEqual(text(for: alice), "ship the fix")
        XCTAssertEqual(voice.status, .idle)
    }

    func testReleasingBeforePermissionArrivesNeverStartsRecording() {
        engine.authorization = .notDetermined
        engine.deferAuthorization = true

        voice.beginHold(on: alice)
        XCTAssertEqual(voice.status, .askingPermission)
        voice.endHold()

        engine.authorization = .authorized
        engine.deliverAuthorization()

        XCTAssertEqual(engine.startCount, 0, "permission granted after the key came up starts nothing")
        XCTAssertNil(voice.target)
    }

    func testPermissionRefusalNamesTheMicrophoneWhenThatIsWhatIsMissing() {
        engine.authorization = .denied
        engine.microphoneDenied = true
        engine.speechDenied = false

        voice.beginHold(on: alice)

        XCTAssertEqual(voice.settingsPane, .microphone)
        guard case .unavailable(let message) = voice.status else {
            return XCTFail("expected .unavailable, got \(voice.status)")
        }
        XCTAssertTrue(message.contains("microphone"))
        XCTAssertEqual(engine.startCount, 0)
    }

    func testPermissionRefusalNamesSpeechRecognitionWhenThatIsWhatIsMissing() {
        engine.authorization = .denied
        engine.microphoneDenied = false
        engine.speechDenied = true

        voice.beginHold(on: alice)

        XCTAssertEqual(voice.settingsPane, .speechRecognition)
        guard case .unavailable(let message) = voice.status else {
            return XCTFail("expected .unavailable, got \(voice.status)")
        }
        XCTAssertTrue(message.contains("speech recognition"))
    }

    func testAMissingFinalResultDoesNotLeaveTheComposerStuck() async {
        voice.finalizeTimeout = .milliseconds(60)
        voice.beginHold(on: alice)
        engine.emit(.volatile(text: "half a sentence", start: 0, duration: 1))
        voice.endHold()
        XCTAssertEqual(voice.status, .finishing)

        try? await Task.sleep(for: .milliseconds(220))

        XCTAssertNil(voice.target, "the capture does not hang about waiting forever")
        XCTAssertEqual(text(for: alice), "half a sentence", "what was heard is kept")
        // And it does not pretend the recogniser finished properly.
        XCTAssertTrue(voice.wasInterrupted)
        guard case .failed(let message) = voice.status else {
            return XCTFail("expected .failed, got \(voice.status)")
        }
        XCTAssertTrue(message.contains("kept"))
    }

    func testAnEngineThatStopsWhileYouAreStillTalkingSaysSo() {
        voice.beginHold(on: alice)
        engine.emit(.volatile(text: "mid sentence", start: 0, duration: 1))
        engine.emit(.finished)   // nobody let go

        XCTAssertEqual(text(for: alice), "mid sentence")
        XCTAssertTrue(voice.wasInterrupted)
        XCTAssertEqual(voice.interruptedTarget, alice)
        guard case .failed(let message) = voice.status else {
            return XCTFail("expected .failed, got \(voice.status)")
        }
        XCTAssertTrue(message.contains("before you let go"))
    }

    func testANoticeIsShownWithoutEndingTheDictation() {
        voice.beginHold(on: alice)
        engine.emit(.finalized(text: "first minute", start: 0, duration: 60))
        engine.emit(.notice("The recogniser started a new segment."))

        XCTAssertTrue(voice.isCapturing, "a notice is not the end")
        XCTAssertEqual(voice.notice, "The recogniser started a new segment.")
        XCTAssertEqual(text(for: alice), "first minute")
    }

    func testNothingHeardIsSaidPlainly() async {
        voice.finalizeTimeout = .milliseconds(60)
        voice.beginHold(on: alice)
        voice.endHold()
        try? await Task.sleep(for: .milliseconds(220))

        XCTAssertEqual(voice.status, .failed("No speech was recognised."))
    }

    func testAnAudioFailureEndsTheCaptureWithAReadableMessage() {
        voice.beginHold(on: alice)
        engine.emit(.failed(.noAudioInput))

        XCTAssertNil(voice.target)
        guard case .failed(let message) = voice.status else {
            return XCTFail("expected .failed, got \(voice.status)")
        }
        XCTAssertTrue(message.contains("microphone"))
    }

    func testHoldingTwiceDoesNotStartTwoCaptures() {
        voice.beginHold(on: alice)
        voice.beginHold(on: bob)
        XCTAssertEqual(engine.startCount, 1)
        XCTAssertEqual(voice.target, alice)
    }
}
