import AppKit
import XCTest
import MarmyRuntime
@testable import MarmyUI

/// The scroll fix, against a real tmux client.
///
/// Opt in with `MARMY_RUN_TMUX_TESTS=1`. It uses its own private socket with
/// `-f /dev/null` and starts nothing but a small Python fixture that records the
/// raw bytes its pane receives — no agent CLI, no model, and the user's tmux
/// server is never contacted.
@MainActor
final class TerminalScrollIntegrationTests: XCTestCase {

    private var root: URL!
    private var socketName: String!
    private var tmux: TmuxClient!
    private var window: NSWindow!
    private var pane: TerminalPane?
    private var recordingPath: String!

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MARMY_RUN_TMUX_TESTS"] == "1",
            "set MARMY_RUN_TMUX_TESTS=1 to run the tmux integration tests")
        let locator = ExecutableLocator()
        guard let tmuxPath = locator.locate("tmux") else { throw XCTSkip("tmux is not installed") }
        guard let python = locator.locate("python3") else { throw XCTSkip("python3 is not installed") }

        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarmyScrollTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        socketName = "marmy-scroll-\(UUID().uuidString.prefix(8).lowercased())"
        recordingPath = root.appendingPathComponent("received.bin").path

        // A pane that puts its tty in raw mode and writes every byte it receives
        // straight to a file, so nothing is buffered waiting for a newline.
        let fixture = root.appendingPathComponent("record.py")
        try """
        import os, sys, tty
        fd = sys.stdin.fileno()
        tty.setraw(fd)
        out = open(\(escaped(recordingPath)), "wb", buffering=0)
        while True:
            data = os.read(fd, 4096)
            if not data:
                break
            out.write(data)
        """.write(to: fixture, atomically: true, encoding: .utf8)

        tmux = TmuxClient(
            executablePath: tmuxPath,
            server: .named(socketName, configFile: "/dev/null"),
            runner: SystemCommandRunner())

        let started = try awaitValue { try await self.tmux.newSession(
            name: "recorder", directory: self.root.path,
            executable: python, arguments: [fixture.path]) }

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.makeKeyAndOrderFront(nil)

        let identity = TerminalIdentity(
            target: .node(UUID()),
            server: try awaitValue { try await self.tmux.serverIdentity()! },
            sessionID: started.sessionID,
            paneID: started.paneID)
        let controller = TerminalController()
        let pane = controller.pane(
            for: identity,
            sessionName: started.sessionName,
            attachment: tmux.attachment(sessionID: started.sessionID))
        window.contentView?.addSubview(pane.view)
        pane.view.frame = window.contentView?.bounds ?? .zero
        self.pane = pane
        settle(seconds: 1.5)
    }

    override func tearDown() {
        pane?.stop()
        window?.orderOut(nil)
        if let tmuxPath = ExecutableLocator().locate("tmux"), let socketName {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tmuxPath)
            process.arguments = ["-L", socketName, "-f", "/dev/null", "kill-server"]
            try? process.run()
            process.waitUntilExit()
        }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: - Helpers

    private func escaped(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func awaitValue<T>(_ work: @escaping () async throws -> T) throws -> T {
        let expectation = expectation(description: "async work")
        var result: Result<T, Error>?
        Task {
            do { result = .success(try await work()) } catch { result = .failure(error) }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 15)
        return try XCTUnwrap(result).get()
    }

    private func settle(seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private var receivedBytes: Data {
        (try? Data(contentsOf: URL(fileURLWithPath: recordingPath))) ?? Data()
    }

    private func wheelEvent(lines: Int32) throws -> NSEvent {
        let cgEvent = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
            wheel1: lines, wheel2: 0, wheel3: 0))
        return try XCTUnwrap(NSEvent(cgEvent: cgEvent))
    }

    // MARK: - Tests

    func testWheelEventsReachingTheTerminalWouldTypeIntoTheAgent() throws {
        // This is the defect, written down: with the wheel delivered to
        // SwiftTerm, a tmux client on the alternate screen turns each line into
        // an arrow key and sends it to whatever the agent is running.
        let pane = try XCTUnwrap(self.pane)
        let before = receivedBytes.count

        for _ in 0..<5 {
            pane.view.scrollWheel(with: try wheelEvent(lines: 1))
        }
        settle(seconds: 1.0)

        let arrows = receivedBytes.dropFirst(before)
        XCTAssertFalse(arrows.isEmpty, "SwiftTerm's own handling does send keys — this is what we prevent")
        let text = String(decoding: arrows, as: UTF8.self)
        XCTAssertTrue(text.contains("[A") || text.contains("OA"), "and they are cursor keys: \(Array(arrows))")
    }

    func testTheScrollMonitorSendsNothingToTheAgent() throws {
        let pane = try XCTUnwrap(self.pane)
        // Start from a clean slate after the previous keystrokes settle.
        settle(seconds: 0.5)
        let before = receivedBytes.count

        var reported: [Int] = []
        let monitor = TerminalScrollMonitor()
        monitor.terminalView = { pane.view }
        monitor.shouldReportScroll = { true }
        monitor.onScrollLines = { reported.append($0) }
        monitor.hitTest = { _, _ in pane.view }

        for _ in 0..<5 {
            let event = try wheelEvent(lines: 1)
            XCTAssertNil(monitor.handle(event), "the event is taken before the terminal can see it")
        }
        settle(seconds: 1.0)

        XCTAssertEqual(receivedBytes.count, before, "not one byte reaches the agent")
        XCTAssertEqual(reported.count, 5, "every gesture went to Marmy's history instead")
    }

    func testHistoryReadsTheRealScrollbackWithoutTouchingThePane() throws {
        // A second session that echoes what it is sent, so it has real
        // scrollback to read. The recorder pane is left completely alone.
        let tmuxPath = ExecutableLocator().locate("tmux")!
        let printer = try awaitValue { try await self.tmux.newSession(
            name: "printer", directory: self.root.path, executable: "/bin/cat", arguments: []) }

        for index in 1...120 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tmuxPath)
            process.arguments = [
                "-L", socketName, "-f", "/dev/null",
                "send-keys", "-t", "=printer:", "-l", "history line \(index)\n",
            ]
            try process.run()
            process.waitUntilExit()
        }
        settle(seconds: 1.0)
        let recorderBytesBefore = receivedBytes

        let history = try awaitValue { () -> PaneHistory in
            let server = try await self.tmux.serverIdentity()!
            return try await AgentRuntime(
                tmux: self.tmux,
                store: RuntimeStore(directoryURL: self.root.appendingPathComponent("runtime"))
            ).history(
                paneID: printer.paneID,
                sessionID: printer.sessionID,
                onServer: server,
                maxLines: 500)
        }

        XCTAssertTrue(history.text.contains("history line 1"), "the earliest line is there to be read")
        XCTAssertTrue(history.text.contains("history line 120"))
        XCTAssertGreaterThan(history.capturedLines, 100)
        XCTAssertEqual(receivedBytes, recorderBytesBefore, "reading history sends nothing to any pane")
    }
}
