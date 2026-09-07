import XCTest
import MarmyCore
@testable import MarmyUI

/// Wheel gestures being added up, and the run they belong to.
///
/// The point of the token: a drain that has been retired — because the terminal
/// changed, or something is about to be typed — can still have a request in
/// flight, and whatever it does when it lands must not touch the gestures
/// somebody is making now.
@MainActor
final class TerminalScrollDrainTests: XCTestCase {

    private var bench: TestBench!
    private var env: AppEnvironment { bench.env }

    override func setUpWithError() throws {
        bench = try TestBench()
    }

    override func tearDownWithError() throws {
        bench.cleanUp()
    }

    private func startDrain(lines: Int = 3) -> AppEnvironment.ScrollDrain? {
        env.scrollTerminal(lines: lines)
        return env.scrollDrain
    }

    func testALateErrorFromARetiredDrainLeavesTheNewOneAlone() async throws {
        try await bench.bindEverything()
        env.syncTerminal()
        let first = try XCTUnwrap(startDrain(), "a gesture starts a drain")

        // The terminal changed, so this run is over — but its request is still
        // in flight somewhere.
        env.retireScrollDrain()
        let second = try XCTUnwrap(startDrain(lines: 5), "and a new gesture starts a new one")
        XCTAssertNotEqual(first.token, second.token)

        // The old one finally fails.
        env.clearScrollDrain(ifToken: first.token)

        XCTAssertEqual(env.scrollDrain?.token, second.token,
                       "the gestures being made now survive it")
        env.clearScrollDrain(ifToken: second.token)
        XCTAssertNil(env.scrollDrain, "and its own completion does end it")
    }

    func testGesturesForOneTerminalAreAddedUpRatherThanSentOneByOne() async throws {
        try await bench.bindEverything()
        env.syncTerminal()
        _ = startDrain(lines: 2)
        let token = env.scrollDrain?.token

        env.scrollTerminal(lines: 3)
        env.scrollTerminal(lines: 4)

        XCTAssertEqual(env.scrollDrain?.token, token, "one run, not three")
        XCTAssertGreaterThanOrEqual(env.scrollDrain?.lines ?? 0, 3,
                                    "later gestures joined the one in flight")
    }

    func testLookingAtAnotherAgentEndsTheRun() async throws {
        try await bench.bindEverything()
        env.syncTerminal()
        _ = startDrain()
        XCTAssertNotNil(env.scrollDrain)

        env.select(node: bench.workers[0].id)

        XCTAssertNil(env.scrollDrain, "nothing queued may land on the terminal that replaced it")
    }
}
