import AppKit
import XCTest
import MarmyCore
import MarmyRuntime
@testable import MarmyUI

/// Scrolling reads tmux's real scrollback and sends nothing to the agent.
@MainActor
final class TerminalHistoryTests: XCTestCase {

    private final class FixtureHistorySource: PaneHistorySource {
        var responses: [WorkTarget: PaneHistory] = [:]
        var error: Error?
        private(set) var requests: [HistoryRequest] = []
        /// Set to hold a read open until `finish()` is called.
        var gate: CheckedContinuation<Void, Never>?
        var isGated = false

        func history(for request: HistoryRequest) async throws -> PaneHistory {
            requests.append(request)
            if isGated {
                await withCheckedContinuation { gate = $0 }
            }
            if let error { throw error }
            return responses[request.target] ?? PaneHistory(
                paneID: "%1", text: "", scrollbackLines: 0, capturedLines: 0, capturedAt: Date())
        }

        func finish() {
            let waiting = gate
            gate = nil
            waiting?.resume()
        }
    }

    private let alice = WorkTarget.node(UUID())
    private let bob = WorkTarget.node(UUID())
    private let server = TmuxServerIdentity(pid: 5, socketPath: "/tmp/s", startTime: 1)

    private func identity(_ target: WorkTarget, pane: String = "%1", generation: String = "g1") -> TerminalIdentity {
        TerminalIdentity(
            target: target, server: server, sessionID: "$1", paneID: pane, generation: generation)
    }

    private func snapshot(_ text: String, lines: Int = 10, total: Int = 10) -> PaneHistory {
        PaneHistory(
            paneID: "%1", text: text, scrollbackLines: total, capturedLines: lines,
            omittedScrollbackLines: 0,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testScrollingUpOpensTheRealScrollback() async {
        let source = FixtureHistorySource()
        source.responses[alice] = snapshot("earliest line\nlatest line", lines: 2, total: 2)
        let controller = TerminalHistoryController(source: source)

        await controller.scrolled(lines: 3, on: alice, identity: identity(alice), clientPID: 42)

        XCTAssertTrue(controller.isShowingHistory)
        XCTAssertEqual(controller.snapshot?.text, "earliest line\nlatest line")
        XCTAssertEqual(controller.initialLinesFromBottom, 3, "it opens where the gesture left off")
        XCTAssertEqual(source.requests.count, 1)
        XCTAssertEqual(source.requests[0].clientPID, 42, "the read is tied to the client on screen")
    }

    func testScrollingDownAtTheLiveTerminalDoesNothing() async {
        let source = FixtureHistorySource()
        let controller = TerminalHistoryController(source: source)

        await controller.scrolled(lines: -4, on: alice, identity: identity(alice), clientPID: 42)

        XCTAssertFalse(controller.isShowingHistory)
        XCTAssertTrue(source.requests.isEmpty)
    }

    func testTheSnapshotIsHeldStillWhileOutputKeepsArriving() async {
        let source = FixtureHistorySource()
        source.responses[alice] = snapshot("first read")
        let controller = TerminalHistoryController(source: source)
        await controller.scrolled(lines: 2, on: alice, identity: identity(alice), clientPID: 42)

        // The pane keeps producing output; the view must not move under the user.
        source.responses[alice] = snapshot("first read\nnew output")
        XCTAssertEqual(controller.snapshot?.text, "first read")
        XCTAssertEqual(source.requests.count, 1, "nothing is re-read behind the user's back")

        await controller.refresh()
        XCTAssertEqual(controller.snapshot?.text, "first read\nnew output", "refresh is explicit")
    }

    func testReturningToLiveClearsEverything() async {
        let source = FixtureHistorySource()
        source.responses[alice] = snapshot("history")
        let controller = TerminalHistoryController(source: source)
        await controller.scrolled(lines: 1, on: alice, identity: identity(alice), clientPID: 42)

        controller.returnToLive()

        XCTAssertFalse(controller.isShowingHistory)
        XCTAssertNil(controller.snapshot)
        XCTAssertEqual(controller.initialLinesFromBottom, 0)
    }

    func testLookingAtAnotherAgentClosesTheHistory() async {
        let source = FixtureHistorySource()
        source.responses[alice] = snapshot("alice's transcript")
        let controller = TerminalHistoryController(source: source)
        await controller.scrolled(lines: 1, on: alice, identity: identity(alice), clientPID: 42)

        controller.selectionChanged(to: bob)

        XCTAssertFalse(controller.isShowingHistory, "history belongs to one agent")
        XCTAssertNil(controller.snapshot)
    }

    func testAReadThatFailsSaysSoRatherThanShowingNothing() async {
        let source = FixtureHistorySource()
        source.error = RuntimeError.identityMismatch(detail: "Session “build” has ended.")
        let controller = TerminalHistoryController(source: source)

        await controller.scrolled(lines: 2, on: alice, identity: identity(alice), clientPID: 42)

        XCTAssertTrue(controller.isShowingHistory)
        XCTAssertNil(controller.snapshot)
        XCTAssertTrue(controller.failure?.contains("has ended") ?? false)
    }

    func testALateReadForAClosedHistoryIsIgnored() async {
        let source = FixtureHistorySource()
        source.responses[alice] = snapshot("slow read")
        source.isGated = true
        let controller = TerminalHistoryController(source: source)

        let opening = Task {
            await controller.scrolled(lines: 2, on: alice, identity: self.identity(alice), clientPID: 42)
        }
        try? await Task.sleep(for: .milliseconds(40))
        controller.returnToLive()
        source.finish()
        await opening.value

        XCTAssertFalse(controller.isShowingHistory)
        XCTAssertNil(controller.snapshot, "a read that lands after the view closed changes nothing")
    }

    func testAReconnectClosesTheHistoryEvenForTheSameAgent() async {
        let source = FixtureHistorySource()
        source.responses[alice] = snapshot("before the reconnect")
        let controller = TerminalHistoryController(source: source)
        await controller.scrolled(lines: 2, on: alice, identity: identity(alice), clientPID: 42)

        // Same agent, new client and pane: what is on screen is not this.
        controller.identityChanged(to: identity(alice, pane: "%9", generation: "g2"))

        XCTAssertFalse(controller.isShowingHistory)
        XCTAssertNil(controller.snapshot)
    }

    func testASnapshotFromABeforeReconnectReadCannotAppearAfterIt() async {
        let source = FixtureHistorySource()
        source.responses[alice] = snapshot("stale transcript")
        source.isGated = true
        let controller = TerminalHistoryController(source: source)

        let opening = Task {
            await controller.scrolled(lines: 2, on: alice, identity: identity(alice), clientPID: 42)
        }
        try? await Task.sleep(for: .milliseconds(40))
        controller.identityChanged(to: identity(alice, pane: "%9", generation: "g2"))
        source.finish()
        await opening.value

        XCTAssertNil(controller.snapshot, "a read for the old client never lands")
        XCTAssertFalse(controller.isShowingHistory)
    }

    // MARK: - The wheel

    /// A real wheel event, built without touching the system event stream.
    private func wheelEvent(deltaY: Int32, at point: CGPoint, in window: NSWindow) -> NSEvent? {
        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
            wheel1: deltaY, wheel2: 0, wheel3: 0)
        else { return nil }
        cgEvent.location = point
        guard let event = NSEvent(cgEvent: cgEvent) else { return nil }
        return event
    }

    func testTheWheelOverTheTerminalIsSwallowedAndReportedAsLines() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        let terminal = MarmyTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView?.addSubview(terminal)
        window.makeKeyAndOrderFront(nil)

        var reported: [Int] = []
        let monitor = TerminalScrollMonitor()
        monitor.terminalView = { terminal }
        monitor.shouldReportScroll = { true }
        monitor.onScrollLines = { reported.append($0) }
        // The event would be delivered to the terminal; how AppKit works that out
        // is not what this test is about.
        monitor.hitTest = { _, _ in terminal }

        let event = try XCTUnwrap(wheelEvent(deltaY: 3, at: CGPoint(x: 10, y: 10), in: window))
        let passedThrough = monitor.handle(event)

        XCTAssertNil(passedThrough, "the event never reaches the terminal, so nothing is typed")
        XCTAssertEqual(reported, [3])
        window.orderOut(nil)
    }

    func testTheWheelIsLeftAloneWhileHistoryIsOpen() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        let terminal = MarmyTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView?.addSubview(terminal)
        window.makeKeyAndOrderFront(nil)

        let overlayScrollView = NSScrollView(frame: terminal.bounds)
        window.contentView?.addSubview(overlayScrollView)

        let monitor = TerminalScrollMonitor()
        monitor.terminalView = { terminal }
        monitor.hitTest = { _, _ in overlayScrollView }   // history is on top

        let event = try XCTUnwrap(wheelEvent(deltaY: 2, at: CGPoint(x: 10, y: 10), in: window))
        XCTAssertNotNil(monitor.handle(event), "the history view gets its own scrolling")
        window.orderOut(nil)
    }

    func testAWheelSomewhereElseIsLeftAlone() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        let terminal = MarmyTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView?.addSubview(terminal)
        window.makeKeyAndOrderFront(nil)

        var reported: [Int] = []
        let monitor = TerminalScrollMonitor()
        monitor.terminalView = { terminal }
        monitor.onScrollLines = { reported.append($0) }
        // Over the sidebar, say: ordinary scrolling.
        monitor.hitTest = { _, _ in window.contentView }

        let event = try XCTUnwrap(wheelEvent(deltaY: 3, at: .zero, in: window))
        XCTAssertNotNil(monitor.handle(event))
        XCTAssertTrue(reported.isEmpty)
        window.orderOut(nil)
    }

    func testWheelEventsAreSwallowedWhileHistoryIsStillLoading() throws {
        // The window between the gesture and the overlay existing is where a
        // fast flick used to slip through into the agent.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        let terminal = MarmyTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView?.addSubview(terminal)
        window.makeKeyAndOrderFront(nil)

        var reported: [Int] = []
        let monitor = TerminalScrollMonitor()
        monitor.terminalView = { terminal }
        monitor.hitTest = { _, _ in terminal }
        // History is opening, so no further gestures should move it…
        monitor.shouldReportScroll = { false }
        monitor.onScrollLines = { reported.append($0) }

        for _ in 0..<8 {
            let event = try XCTUnwrap(wheelEvent(deltaY: 2, at: .zero, in: window))
            XCTAssertNil(monitor.handle(event), "…but every one of them is still taken from the terminal")
        }
        XCTAssertTrue(reported.isEmpty)
        window.orderOut(nil)
    }

    func testAWheelOverASubviewOfTheTerminalIsAlsoSwallowed() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        let terminal = MarmyTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let child = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        terminal.addSubview(child)
        window.contentView?.addSubview(terminal)
        window.makeKeyAndOrderFront(nil)

        let monitor = TerminalScrollMonitor()
        monitor.terminalView = { terminal }
        monitor.hitTest = { _, _ in child }

        let event = try XCTUnwrap(wheelEvent(deltaY: 1, at: .zero, in: window))
        XCTAssertNil(monitor.handle(event))
        window.orderOut(nil)
    }

    func testTrackpadPixelsBecomeWholeLines() throws {
        let monitor = TerminalScrollMonitor()
        // A classic wheel notch always moves at least one line.
        let source = CGEvent(
            scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0)
        let event = try XCTUnwrap(NSEvent(cgEvent: try XCTUnwrap(source)))
        XCTAssertEqual(monitor.lines(for: event, in: nil), 1)
    }
}
