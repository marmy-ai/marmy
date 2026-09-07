import AppKit
import XCTest
import MarmyCore
import MarmyRuntime
@testable import MarmyUI

/// The rules that cross state, dictation, and the terminal.
@MainActor
final class AppEnvironmentTests: XCTestCase {

    private var bench: TestBench!

    override func setUpWithError() throws {
        bench = try TestBench()
    }

    override func tearDown() {
        bench.cleanUp()
    }

    // MARK: - Dictation belongs to one agent

    func testSwitchingAgentsStopsDictation() {
        let target = WorkTarget.node(bench.workers[0].id)
        bench.env.voice.beginHold(on: target)
        XCTAssertTrue(bench.env.voice.isCapturing)

        bench.env.select(node: bench.workers[1].id)

        XCTAssertFalse(bench.env.voice.isCapturing)
        XCTAssertNil(bench.env.voice.target)
        XCTAssertEqual(bench.speech.cancelCount, 1)
    }

    func testSwitchingToTheGraphStopsDictation() {
        // The target does not change, but the user has looked away.
        let target = WorkTarget.node(bench.workers[0].id)
        bench.env.select(node: bench.workers[0].id)
        bench.env.voice.beginHold(on: target)
        XCTAssertTrue(bench.env.voice.isCapturing)

        bench.model.mode = .topology

        XCTAssertFalse(bench.env.voice.isCapturing)
    }

    func testDeletingTheAgentBeingDictatedToStopsDictation() async {
        let target = WorkTarget.node(bench.workers[0].id)
        bench.env.select(node: bench.workers[0].id)
        bench.env.voice.beginHold(on: target)
        bench.speech.emit(.volatile(text: "half a thought", start: 0, duration: 1))
        XCTAssertTrue(bench.env.voice.isCapturing)

        await bench.model.deleteNode(bench.workers[0].id)

        XCTAssertFalse(bench.env.voice.isCapturing)
        XCTAssertNil(bench.env.voice.target)
    }

    func testLosingFocusStopsDictation() {
        bench.env.voice.beginHold(on: .node(bench.workers[0].id))
        bench.env.stopCapture(reason: nil)

        XCTAssertFalse(bench.env.voice.isCapturing)
        XCTAssertFalse(bench.env.keyboard.isHolding)
    }

    func testWordsSpokenAreKeptEvenWhenTheyCannotBePasted() {
        // Nothing is attached, so there is nowhere to paste. The words must
        // still be offered back rather than disappearing.
        let target = WorkTarget.node(bench.workers[0].id)
        bench.env.select(node: bench.workers[0].id)
        bench.env.voice.beginHold(on: target)
        bench.speech.emit(.finalized(text: "something worth keeping", start: 0, duration: 2))
        bench.env.voice.endHold()
        bench.speech.emit(.finished)

        let pending = bench.env.dictation.item(for: target)
        XCTAssertEqual(pending?.text, "something worth keeping")
    }

    func testMovingAwayMidSentenceKeepsTheWordsForTheAgentTheyWereSpokenTo() {
        let origin = WorkTarget.node(bench.workers[0].id)
        bench.env.select(node: bench.workers[0].id)
        bench.env.voice.beginHold(on: origin)
        bench.speech.emit(.finalized(text: "the first half", start: 0, duration: 2))
        bench.speech.emit(.volatile(text: "and the second half", start: 2, duration: 2))

        // Control-Tab to the next agent, mid-sentence.
        bench.env.select(node: bench.workers[1].id)

        let kept = bench.env.dictation.item(for: origin)
        XCTAssertEqual(kept?.text, "the first half and the second half", "all of it, not just the committed part")
        XCTAssertNil(bench.env.dictation.item(for: .node(bench.workers[1].id)),
                     "and none of it followed the selection")
        if case .failed(let reason) = kept?.state {
            XCTAssertTrue(reason.contains("not put into the prompt"), reason)
        } else {
            XCTFail("expected words held with a reason, got \(String(describing: kept?.state))")
        }
    }

    func testALateResultCannotChangeAnAlreadyHeldCapture() {
        let origin = WorkTarget.node(bench.workers[0].id)
        bench.env.select(node: bench.workers[0].id)
        bench.env.voice.beginHold(on: origin)
        bench.speech.emit(.finalized(text: "what was said", start: 0, duration: 2))
        let retired = bench.speech.captureHandler()
        bench.env.select(node: bench.workers[1].id)

        bench.speech.emitFromRetiredRun(
            .finalized(text: "something else entirely", start: 0, duration: 2), using: retired)

        XCTAssertEqual(bench.env.dictation.item(for: origin)?.text, "what was said")
        XCTAssertNil(bench.env.dictation.item(for: .node(bench.workers[1].id)))
    }

    func testASecondHoldCannotPushAsideWordsStillWaiting() {
        let target = WorkTarget.node(bench.workers[0].id)
        bench.env.select(node: bench.workers[0].id)
        bench.env.voice.beginHold(on: target)
        bench.speech.emit(.finalized(text: "the first dictation", start: 0, duration: 2))
        bench.env.voice.endHold()
        bench.speech.emit(.finished)
        XCTAssertNotNil(bench.env.dictation.item(for: target))

        bench.env.micPressed()

        XCTAssertFalse(bench.env.voice.isCapturing, "the first lot has to be dealt with first")
        XCTAssertEqual(bench.model.banner?.kind, .warning)
        XCTAssertEqual(bench.env.dictation.item(for: target)?.text, "the first dictation")
    }

    func testDiscardingRemovesOnlyThatCapture() {
        let first = WorkTarget.node(bench.workers[0].id)
        let second = WorkTarget.node(bench.workers[1].id)
        for (target, words) in [(first, "for the first"), (second, "for the second")] {
            bench.env.select(node: target.nodeID!)
            bench.env.voice.beginHold(on: target)
            bench.speech.emit(.finalized(text: words, start: 0, duration: 2))
            bench.env.voice.endHold()
            bench.speech.emit(.finished)
        }
        let toDiscard = try? XCTUnwrap(bench.env.dictation.item(for: first))
        bench.env.discardDictation(toDiscard!.id)

        XCTAssertNil(bench.env.dictation.item(for: first))
        XCTAssertEqual(bench.env.dictation.item(for: second)?.text, "for the second")
    }

    func testAContextChangeIsNotMistakenForLettingGo() {
        // The engine reports the end of the capture synchronously inside stop().
        // A context cancel must not look like a release, and must not paste.
        bench.speech.finishesOnStop = true
        let origin = WorkTarget.node(bench.workers[0].id)
        bench.env.select(node: bench.workers[0].id)
        bench.env.voice.beginHold(on: origin)
        bench.speech.emit(.finalized(text: "words for the first agent", start: 0, duration: 2))

        bench.env.stopCapture(reason: nil)

        let kept = bench.env.dictation.item(for: origin)
        XCTAssertEqual(kept?.text, "words for the first agent")
        if case .failed = kept?.state {} else {
            XCTFail("expected the words held for their own agent, got \(String(describing: kept?.state))")
        }
        XCTAssertEqual(bench.env.dictation.items(for: origin).count, 1, "and only once")
        XCTAssertFalse(bench.env.voice.isCapturing)
    }

    func testAHoldEndingNormallyStillDelivers() {
        bench.speech.finishesOnStop = true
        let target = WorkTarget.node(bench.workers[0].id)
        bench.env.select(node: bench.workers[0].id)
        bench.env.voice.beginHold(on: target)
        bench.speech.emit(.finalized(text: "please look at the build", start: 0, duration: 2))

        bench.env.voice.endHold()

        // No terminal in this bench, so it is held rather than pasted — but it
        // is held as a delivery attempt, not as a context cancel.
        XCTAssertEqual(bench.env.dictation.item(for: target)?.text, "please look at the build")
        XCTAssertEqual(bench.env.dictation.items(for: target).count, 1)
    }

    // MARK: - Keyboard

    func testTheKeyboardHoldTalksToTheSelectedAgent() {
        bench.env.select(node: bench.workers[1].id)
        bench.env.keyboard.schedule = { _, body in body() }
        bench.env.keyboard.context = {
            KeyboardCoordinator.Context(isWorkMode: true, terminalHasFocus: true)
        }

        _ = bench.env.keyboard.handleKeyDown(code: KeyboardCoordinator.spaceKeyCode, modifiers: [], isRepeat: false)

        // No terminal is attached in this bench, so it says so rather than
        // recording into nowhere.
        XCTAssertNil(bench.env.voice.target)
        XCTAssertEqual(bench.model.banner?.kind, .failure)
    }

    func testKeyboardNavigationMovesBetweenPeers() {
        bench.env.select(node: bench.workers[0].id)
        bench.env.keyboard.context = {
            KeyboardCoordinator.Context(isWorkMode: true, terminalHasFocus: true)
        }

        _ = bench.env.keyboard.handleKeyDown(
            code: KeyboardCoordinator.tabKeyCode, modifiers: [.control], isRepeat: false)
        XCTAssertEqual(bench.model.selectedNodeID, bench.workers[1].id)

        _ = bench.env.keyboard.handleKeyDown(
            code: KeyboardCoordinator.upArrowKeyCode, modifiers: [.command], isRepeat: false)
        XCTAssertEqual(bench.model.selectedNodeID, bench.manager.id)
    }
}

/// A file that reached the app but not the prompt is handed back, not lost.
@MainActor
final class RecoveredAttachmentTests: XCTestCase {
    private var harness: TestBench!
    private var pasteboard: NSPasteboard!

    override func setUpWithError() throws {
        harness = try TestBench()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("ai.marmy.tests.\(UUID().uuidString)"))
        harness.env.attachmentPasteboard = pasteboard
    }

    override func tearDownWithError() throws {
        pasteboard.releaseGlobally()
        harness.cleanUp()
    }

    func testAFailedInsertionKeepsThePathAndCanCopyIt() throws {
        let env = harness.env
        env.recordInsertFailure(
            MarmyTerminalView.Insertion(text: "'/tmp/shot.png'", recoveredPath: "/tmp/shot.png"),
            reason: "that pane is gone")

        XCTAssertEqual(env.recoveredAttachmentPath, "/tmp/shot.png",
                       "the file is still on disk, so the path is worth keeping")
        XCTAssertNotNil(env.model.banner)

        env.copyRecoveredAttachmentPath()
        XCTAssertEqual(pasteboard.string(forType: .string), "/tmp/shot.png")

        env.dismissRecoveredAttachment()
        XCTAssertNil(env.recoveredAttachmentPath)
    }

    func testAFailedPlainTextInsertionOffersNoPath() {
        let env = harness.env
        env.recordInsertFailure(
            MarmyTerminalView.Insertion(text: "some dictated words"), reason: "that pane is gone")

        XCTAssertNil(env.recoveredAttachmentPath, "there is no file behind ordinary text")
        XCTAssertNotNil(env.model.banner)
    }
}
