import XCTest
import MarmyCore
@testable import MarmyRuntime

/// One thing at a time in a pane, and no spinning while you wait.
///
/// A trackpad can produce dozens of wheel events a second. Each one used to find
/// the pane busy and loop looking again; now it waits properly and is handed the
/// pane in turn.
final class PaneSerializationTests: XCTestCase {

    private var environment: TestEnvironment!
    private var runner: FakeCommandRunner!

    override func setUpWithError() throws {
        environment = try TestEnvironment()
        runner = FakeCommandRunner()
        runner.stub("display-message", TmuxFixtures.serverIdentity())
        runner.stub("list-sessions", TmuxFixtures.sessions([
            (id: "$1", name: "lead"), (id: "$2", name: "build"),
        ]))
        runner.stub("list-panes", TmuxFixtures.panes([
            (pane: "%1", session: "$1", name: "lead"),
            (pane: "%2", session: "$2", name: "build"),
        ]))
        // `display-message` answers two different questions; the pane's mode is
        // the one with the format in it.
        runner.respond = { call in
            guard call.subcommand == "display-message",
                  call.arguments.contains(where: { $0.contains("pane_in_mode") })
            else { return nil }
            return CommandResult(exitCode: 0, standardOutput: "\n")
        }
    }

    override func tearDownWithError() throws {
        environment.cleanUp()
    }

    private func makeRuntime() throws -> AgentRuntime {
        try AgentRuntime(
            tmux: TmuxClient(executablePath: environment.tmuxPath, runner: runner),
            locator: environment.locator,
            store: environment.store,
            trampoline: environment.trampoline)
    }

    private var server: TmuxServerIdentity {
        TmuxServerIdentity(pid: 4242, socketPath: "/tmp/tmux-501/default", startTime: 1700)
    }

    private func target(session: String, pane: String) -> AgentRuntime.DeliveryTarget {
        AgentRuntime.DeliveryTarget(sessionID: session, paneID: pane, server: server)
    }

    /// The order the fake was asked to do things, with each pane's work marked.
    private func paneOrder() -> [String] {
        runner.calls.compactMap { call in
            guard call.subcommand == "send-keys" || call.subcommand == "copy-mode" else { return nil }
            guard let index = call.arguments.firstIndex(of: "-t"),
                  index + 1 < call.arguments.count
            else { return nil }
            return call.arguments[index + 1]
        }
    }

    /// The work each operation does, in the order it was asked for, with the
    /// scroll counts kept so two scrolls can be told apart.
    private func workOrder() -> [String] {
        runner.calls.compactMap { call -> String? in
            guard let subcommand = call.subcommand,
                  ["copy-mode", "send-keys", "load-buffer", "paste-buffer"].contains(subcommand)
            else { return nil }
            if let index = call.arguments.firstIndex(of: "-N"), index + 1 < call.arguments.count {
                return "\(subcommand):\(call.arguments[index + 1])"
            }
            return subcommand
        }
    }

    /// Waits for something to become true, or gives up. Used instead of a guess
    /// at how long an operation ought to take.
    private func waitUntil(timeout: TimeInterval = 3, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    func testAScrollAndAPasteOnOnePaneTakeTurns() async throws {
        // The scroll is held at its first command, and holds the pane with it.
        // If the pane were not held, the paste would go through underneath — and
        // a paste into a pane halfway up its scrollback lands where nobody can
        // see it.
        runner.holdMatching = { $0.subcommand == "copy-mode" }
        let runtime = try makeRuntime()
        let pane = target(session: "$1", pane: "%1")

        async let scrolling: Void? = try? await runtime.scroll(lines: 3, in: pane, nodeID: nil)
        let holding = await waitUntil { self.runner.heldCallCount == 1 }
        XCTAssertTrue(holding, "the scroll should be holding the pane")

        async let pasting: Void? = try? await runtime.paste(
            "hello", toSessionID: "$1", expecting: pane)
        // Long enough that a paste which ignored the pane would have gone.
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(runner.calls(of: "load-buffer").isEmpty,
                      "the paste waited for the pane rather than working around it")

        runner.holdMatching = nil
        runner.releaseHeld()
        _ = await (scrolling, pasting)

        XCTAssertEqual(workOrder(), ["copy-mode", "send-keys:3", "load-buffer", "paste-buffer"],
                       "one finished before the other started")
    }

    func testTwoScrollsOnOnePaneKeepTheirOwnCounts() async throws {
        // Distinguishable gestures: three lines and seven. Interleaved, the
        // counts would not come out in whole operations.
        runner.delay = 0.02
        let runtime = try makeRuntime()
        let pane = target(session: "$1", pane: "%1")

        async let first: Void? = try? await runtime.scroll(lines: 3, in: pane, nodeID: nil)
        async let second: Void? = try? await runtime.scroll(lines: 7, in: pane, nodeID: nil)
        _ = await (first, second)

        let order = workOrder()
        XCTAssertTrue(
            order == ["copy-mode", "send-keys:3", "copy-mode", "send-keys:7"]
                || order == ["copy-mode", "send-keys:7", "copy-mode", "send-keys:3"],
            "each gesture's commands stayed together: \(order)")
    }

    func testTwoPanesDoNotWaitForEachOther() async throws {
        // One pane is held; the other has to get all the way through while it
        // is — no guess about how long anything takes.
        runner.holdMatching = { call in
            call.subcommand == "copy-mode" && call.arguments.contains("%1")
        }
        let runtime = try makeRuntime()

        async let blocked: Void? = try? await runtime.scroll(
            lines: 3, in: target(session: "$1", pane: "%1"), nodeID: nil)
        let holding = await waitUntil { self.runner.heldCallCount == 1 }
        XCTAssertTrue(holding, "the first pane is held")

        async let other: Void? = try? await runtime.scroll(
            lines: 7, in: target(session: "$2", pane: "%2"), nodeID: nil)

        let independent = await waitUntil { self.workOrder().contains("send-keys:7") }
        XCTAssertTrue(independent, "a busy pane does not hold up a different one")
        XCTAssertFalse(workOrder().contains("send-keys:3"), "while the first one is still held")

        runner.holdMatching = nil
        runner.releaseHeld()
        _ = await (blocked, other)
    }

    func testAFailedTurnStillHandsThePaneOn() async throws {
        // The first gesture is refused: the second must not wait forever.
        let runtime = try makeRuntime()
        var stale = target(session: "$9", pane: "%1")
        stale.sessionID = "$9"

        _ = try? await runtime.scroll(lines: 3, in: stale, nodeID: nil)
        try await runtime.scroll(lines: 3, in: target(session: "$1", pane: "%1"), nodeID: nil)

        XCTAssertEqual(paneOrder(), ["%1", "%1"], "the pane was released when the first one threw")
    }
}
