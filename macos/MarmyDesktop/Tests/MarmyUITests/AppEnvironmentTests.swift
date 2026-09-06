import XCTest
import MarmyCore
@testable import MarmyUI

/// The rules that cross state, dictation, and sending.
@MainActor
final class AppEnvironmentTests: XCTestCase {

    private var bench: TestBench!

    override func setUpWithError() throws {
        bench = try TestBench()
    }

    override func tearDown() {
        bench.cleanUp()
    }

    func testSwitchingAgentsStopsDictation() {
        let target = WorkTarget.node(bench.workers[0].id)
        bench.env.voice.beginHold(on: target)
        XCTAssertTrue(bench.env.voice.isCapturing)

        bench.env.select(node: bench.workers[1].id)

        XCTAssertFalse(bench.env.voice.isCapturing)
        XCTAssertNil(bench.env.voice.target)
        XCTAssertFalse(bench.model.drafts.isDictating(target))
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
        XCTAssertFalse(bench.model.drafts.isDictating(target))
    }

    func testDeletingTheAgentBeingDictatedToStopsDictation() async {
        let target = WorkTarget.node(bench.workers[0].id)
        bench.env.select(node: bench.workers[0].id)
        bench.env.voice.beginHold(on: target)
        bench.speech.emit(.partial("half a thought"))
        XCTAssertTrue(bench.env.voice.isCapturing)

        await bench.model.deleteNode(bench.workers[0].id)

        XCTAssertFalse(bench.env.voice.isCapturing)
        XCTAssertNil(bench.env.voice.target)
        XCTAssertTrue(bench.model.drafts.isEmpty(target), "the draft goes with the agent")
    }

    func testLosingFocusStopsDictation() {
        let target = WorkTarget.node(bench.workers[0].id)
        bench.env.voice.beginHold(on: target)
        bench.env.stopCapture(reason: nil)

        XCTAssertFalse(bench.env.voice.isCapturing)
        XCTAssertFalse(bench.env.keyboard.isHolding)
    }

    func testAMessageIsNotSentWhileItIsStillBeingDictated() async throws {
        try await bench.bindEverything()
        let target = WorkTarget.node(bench.workers[0].id)
        bench.env.select(node: bench.workers[0].id)
        bench.model.drafts.setText("send me later", for: target)
        bench.env.voice.beginHold(on: target)

        await bench.env.sendDraft(from: target)

        XCTAssertEqual(bench.model.drafts.text(for: target), "send me later", "nothing was sent or cleared")
        XCTAssertTrue(bench.runner.calls(of: "load-buffer").isEmpty)
    }

    func testTheKeyboardHoldTalksToTheSelectedAgent() {
        bench.env.select(node: bench.workers[1].id)
        bench.env.keyboard.schedule = { _, body in body() }
        bench.env.keyboard.context = {
            KeyboardCoordinator.Context(isWorkMode: true, terminalHasFocus: true)
        }

        _ = bench.env.keyboard.handleKeyDown(code: KeyboardCoordinator.spaceKeyCode, modifiers: [], isRepeat: false)

        XCTAssertEqual(bench.env.voice.target, .node(bench.workers[1].id))
        _ = bench.env.keyboard.handleKeyUp(code: KeyboardCoordinator.spaceKeyCode, modifiers: [])
        XCTAssertEqual(bench.speech.stopCount, 1)
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
