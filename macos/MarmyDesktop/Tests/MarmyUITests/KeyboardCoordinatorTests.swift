import AppKit
import XCTest
@testable import MarmyUI

/// Hold-to-talk and hierarchy keys, without a window or a microphone.
@MainActor
final class KeyboardCoordinatorTests: XCTestCase {

    private var coordinator: KeyboardCoordinator!
    private var pendingTimers: [() -> Void] = []
    private var navigations: [KeyboardCoordinator.Navigation] = []
    private var holds = 0
    private var releases = 0
    private var taps = 0

    private static let letterB: UInt16 = 11

    override func setUp() {
        coordinator = KeyboardCoordinator()
        pendingTimers = []
        navigations = []
        holds = 0
        releases = 0
        taps = 0
        coordinator.context = { KeyboardCoordinator.Context(isWorkMode: true, terminalHasFocus: true) }
        coordinator.schedule = { [weak self] _, body in self?.pendingTimers.append(body) }
        coordinator.onNavigate = { [weak self] in self?.navigations.append($0) }
        coordinator.onHoldBegan = { [weak self] in self?.holds += 1 }
        coordinator.onHoldEnded = { [weak self] in self?.releases += 1 }
        coordinator.onSpaceTap = { [weak self] in self?.taps += 1 }
    }

    private func fireTimers() {
        let timers = pendingTimers
        pendingTimers = []
        for timer in timers { timer() }
    }

    private func space(_ phase: Phase, isRepeat: Bool = false) -> Bool {
        switch phase {
        case .down: return coordinator.handleKeyDown(code: 49, modifiers: [], isRepeat: isRepeat)
        case .up: return coordinator.handleKeyUp(code: 49, modifiers: [])
        }
    }

    enum Phase { case down, up }

    func testAShortTapReachesTheTerminalAsASpace() {
        XCTAssertTrue(space(.down), "the key is held back until we know what it means")
        XCTAssertTrue(space(.up))
        XCTAssertEqual(taps, 1)
        XCTAssertEqual(holds, 0)
    }

    func testHoldingStartsDictationAndReleasingEndsIt() {
        _ = space(.down)
        fireTimers()
        XCTAssertEqual(holds, 1)
        XCTAssertTrue(coordinator.isHolding)

        XCTAssertTrue(space(.up))
        XCTAssertEqual(releases, 1)
        XCTAssertEqual(taps, 0, "a hold is not also a space")
    }

    func testKeyRepeatDoesNotStartASecondCaptureOrLeakSpaces() {
        _ = space(.down)
        fireTimers()
        XCTAssertTrue(space(.down, isRepeat: true))
        XCTAssertTrue(space(.down, isRepeat: true))
        XCTAssertEqual(holds, 1)
        XCTAssertEqual(taps, 0)
    }

    func testTypingQuicklyKeepsTheSpaceBeforeTheNextLetter() {
        // Space down, B down, Space up: the space has to reach the terminal
        // first, or the user sees "b " where they typed " b".
        XCTAssertTrue(space(.down))
        let consumedB = coordinator.handleKeyDown(code: Self.letterB, modifiers: [], isRepeat: false)

        XCTAssertEqual(taps, 1, "the waiting space is flushed before the letter")
        XCTAssertFalse(consumedB, "the letter itself goes to the terminal")
        XCTAssertFalse(coordinator.isWaitingForHold)

        fireTimers()
        XCTAssertEqual(holds, 0, "the cancelled hold timer must not fire later")
        XCTAssertFalse(space(.up), "the space was already delivered")
    }

    func testSpaceIsLeftAloneWhileTypingInAField() {
        coordinator.context = {
            KeyboardCoordinator.Context(isWorkMode: true, terminalHasFocus: false, isEditingText: true)
        }
        XCTAssertFalse(space(.down))
        XCTAssertEqual(taps, 0)
        XCTAssertEqual(holds, 0)
    }

    func testSpaceIsLeftAloneWhileASheetIsUp() {
        coordinator.context = {
            KeyboardCoordinator.Context(isWorkMode: true, terminalHasFocus: true, isModalPresented: true)
        }
        XCTAssertFalse(space(.down))
    }

    func testFocusMovingDuringTheDelayCancelsTheHold() {
        _ = space(.down)
        coordinator.context = { KeyboardCoordinator.Context(isWorkMode: true, terminalHasFocus: false) }
        fireTimers()
        XCTAssertEqual(holds, 0)
        XCTAssertFalse(coordinator.isHolding)
    }

    func testPeerAndHierarchyKeys() {
        XCTAssertTrue(coordinator.handleKeyDown(code: 48, modifiers: [.control], isRepeat: false))
        XCTAssertTrue(coordinator.handleKeyDown(code: 48, modifiers: [.control, .shift], isRepeat: false))
        XCTAssertTrue(coordinator.handleKeyDown(code: 126, modifiers: [.command], isRepeat: false))
        XCTAssertTrue(coordinator.handleKeyDown(code: 125, modifiers: [.command], isRepeat: false))
        XCTAssertEqual(navigations, [.nextPeer, .previousPeer, .parent, .child])
    }

    func testCommandArrowsStayOrdinaryTextNavigationInAField() {
        coordinator.context = {
            KeyboardCoordinator.Context(isWorkMode: true, terminalHasFocus: false, isEditingText: true)
        }
        XCTAssertFalse(coordinator.handleKeyDown(code: 126, modifiers: [.command], isRepeat: false))
        XCTAssertFalse(coordinator.handleKeyDown(code: 125, modifiers: [.command], isRepeat: false))
        XCTAssertTrue(navigations.isEmpty)
    }

    func testHierarchyKeysAreQuietOutsideTheWorkView() {
        coordinator.context = { KeyboardCoordinator.Context(isWorkMode: false, terminalHasFocus: true) }
        XCTAssertFalse(coordinator.handleKeyDown(code: 48, modifiers: [.control], isRepeat: false))
        XCTAssertFalse(coordinator.handleKeyDown(code: 126, modifiers: [.command], isRepeat: false))
        XCTAssertTrue(navigations.isEmpty)
    }

    func testCancellingAHoldReportsTheRelease() {
        _ = space(.down)
        fireTimers()
        coordinator.cancelHold()
        XCTAssertEqual(releases, 1)
        XCTAssertFalse(coordinator.isHolding)
    }
}
