import XCTest
import MarmyCore
@testable import MarmyUI

/// The hold-to-talk state machine, driven entirely by scripted speech events.
/// No microphone is opened and no permission is ever requested from macOS.
@MainActor
final class VoiceControllerTests: XCTestCase {

    private var drafts: DraftStore!
    private var engine: ScriptedSpeechEngine!
    private var voice: VoiceController!
    private let alice = WorkTarget.node(UUID(uuidString: "00000000-0000-4000-8000-000000000001")!)
    private let bob = WorkTarget.node(UUID(uuidString: "00000000-0000-4000-8000-000000000002")!)

    override func setUp() {
        drafts = DraftStore()
        engine = ScriptedSpeechEngine()
        voice = VoiceController(engine: engine, drafts: drafts)
    }

    func testDictationAppendsToTheDraftItStartedOn() {
        drafts.setText("please ", for: alice)
        voice.beginHold(on: alice)
        engine.emit(.partial("check"))
        engine.emit(.partial("check the build"))

        XCTAssertEqual(drafts.text(for: alice), "please check the build",
                       "partial results replace each other instead of piling up")
        voice.endHold()
        engine.emit(.final("check the build twice"))
        XCTAssertEqual(drafts.text(for: alice), "please check the build twice")
        XCTAssertEqual(voice.status, .idle)
        XCTAssertNil(voice.target)
    }

    func testSwitchingAgentsStopsTheCaptureAndKeepsTheWordsWhereTheyWereSpoken() {
        voice.beginHold(on: alice)
        engine.emit(.partial("for alice"))
        let retired = engine.captureHandler()

        voice.cancel()
        engine.emitFromRetiredRun(.final("for alice, later"), using: retired)

        XCTAssertEqual(drafts.text(for: alice), "for alice")
        XCTAssertTrue(drafts.text(for: bob).isEmpty, "a retired transcript reaches nobody else")
        XCTAssertEqual(engine.cancelCount, 1)
    }

    func testALateCallbackFromAnOldRunCannotDisturbANewOne() {
        voice.beginHold(on: alice)
        let firstRun = engine.captureHandler()
        voice.cancel()

        voice.beginHold(on: bob)
        engine.emit(.partial("bob's message"))
        engine.emitFromRetiredRun(.final("alice's leftovers"), using: firstRun)

        XCTAssertEqual(drafts.text(for: bob), "bob's message")
        XCTAssertEqual(voice.target, bob, "the new capture is still running")
        XCTAssertTrue(voice.isCapturing)
    }

    func testALatePartialAfterTheFinalIsIgnored() {
        voice.beginHold(on: alice)
        engine.emit(.partial("hello"))
        voice.endHold()
        engine.emit(.final("hello there"))
        engine.emit(.partial("hello"))

        XCTAssertEqual(drafts.text(for: alice), "hello there", "the finished transcript is not rewritten")
        XCTAssertFalse(drafts.isDictating(alice))
    }

    func testABlankFinalKeepsWhatWasAlreadyHeard() {
        voice.beginHold(on: alice)
        engine.emit(.partial("ship the fix"))
        voice.endHold()
        engine.emit(.final(""))

        XCTAssertEqual(drafts.text(for: alice), "ship the fix")
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
        XCTAssertFalse(drafts.isDictating(alice))
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
        engine.emit(.partial("half a sentence"))
        voice.endHold()
        XCTAssertEqual(voice.status, .finishing)

        try? await Task.sleep(for: .milliseconds(220))

        XCTAssertEqual(voice.status, .idle, "the capture finishes on its own")
        XCTAssertNil(voice.target)
        XCTAssertFalse(drafts.isDictating(alice))
        XCTAssertEqual(drafts.text(for: alice), "half a sentence", "what was heard is kept")
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
        XCTAssertFalse(drafts.isDictating(alice))
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
