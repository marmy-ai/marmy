import XCTest
@testable import MarmyRuntime

/// Exercises the real subprocess path with small fixture programs. Nothing here
/// touches tmux or any agent CLI.
final class CommandRunnerTests: XCTestCase {

    private var directory: URL!
    private let runner = SystemCommandRunner()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CommandRunnerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func fixture(_ name: String, _ script: String) throws -> String {
        let url = directory.appendingPathComponent(name)
        try ("#!/bin/sh\n" + script).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func testCapturesOutputAndExitCode() async throws {
        let path = try fixture("both.sh", "echo out; echo err >&2; exit 3")
        let result = try await runner.run(CommandInvocation(executable: path))

        XCTAssertEqual(result.exitCode, 3)
        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(result.standardOutput, "out\n")
        XCTAssertEqual(result.standardError, "err\n")
        XCTAssertEqual(result.failureText, "err")
    }

    func testLargeOutputOnBothPipesDoesNotDeadlock() async throws {
        // More than a pipe buffer on each stream at once: a runner that read one
        // stream to completion before the other would hang here.
        let path = try fixture("flood.sh", """
        i=0
        while [ $i -lt 400 ]; do
          printf 'stdout %s aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\\n' "$i"
          printf 'stderr %s bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\\n' "$i" >&2
          i=$((i + 1))
        done
        """)
        let result = try await runner.run(CommandInvocation(executable: path, timeout: 20))

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.standardOutput.split(separator: "\n").count, 400)
        XCTAssertEqual(result.standardError.split(separator: "\n").count, 400)
    }

    func testStandardInputIsDelivered() async throws {
        let path = try fixture("cat.sh", "cat")
        let text = "first line\nsecond \u{22}quoted\u{22} line\n"
        let result = try await runner.run(CommandInvocation(
            executable: path, standardInput: Data(text.utf8)))

        XCTAssertEqual(result.standardOutput, text)
    }

    func testInputThatCouldNotBeFullyWrittenIsReported() async throws {
        // The command exits without reading, so most of the payload never
        // arrives. Reporting success would claim a message was delivered.
        let path = try fixture("ignore.sh", "exit 0")
        let payload = Data(repeating: UInt8(ascii: "x"), count: 512 * 1024)
        do {
            _ = try await runner.run(CommandInvocation(
                executable: path, standardInput: payload, timeout: 20))
            XCTFail("expected an input delivery error")
        } catch let error as CommandError {
            guard case .inputNotDelivered = error else {
                return XCTFail("expected .inputNotDelivered, got \(error)")
            }
        }
    }

    func testSmallInputToACommandThatReadsItSucceeds() async throws {
        let path = try fixture("consume.sh", "cat > /dev/null")
        let result = try await runner.run(CommandInvocation(
            executable: path, standardInput: Data("hello".utf8)))
        XCTAssertEqual(result.exitCode, 0)
    }

    func testCancellationBeforeTheProcessStartsStillReturns() async throws {
        // The cancellation can land before the execution has a continuation;
        // marking it finished there would hang this await forever.
        let path = try fixture("slow2.sh", "sleep 30")
        let task = Task { try await runner.run(CommandInvocation(executable: path, timeout: 30)) }
        task.cancel()

        let finished = expectation(description: "the call returns")
        Task {
            do {
                _ = try await task.value
                XCTFail("expected cancellation")
            } catch let error as CommandError {
                if case .cancelled = error {} else { XCTFail("expected .cancelled, got \(error)") }
            } catch {
                XCTFail("unexpected error \(error)")
            }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 10)
    }

    func testMissingExecutableReportsLaunchFailure() async throws {
        do {
            _ = try await runner.run(CommandInvocation(
                executable: directory.appendingPathComponent("nope").path))
            XCTFail("expected a launch failure")
        } catch let error as CommandError {
            guard case .launchFailed(let executable, _) = error else {
                return XCTFail("expected .launchFailed, got \(error)")
            }
            XCTAssertTrue(executable.hasSuffix("nope"))
        }
    }

    func testTimeoutKillsAProcessThatIgnoresSIGTERM() async throws {
        let path = try fixture("stubborn.sh", "trap '' TERM\nsleep 30\n")
        let started = Date()
        do {
            _ = try await runner.run(CommandInvocation(executable: path, timeout: 0.5))
            XCTFail("expected a timeout")
        } catch let error as CommandError {
            guard case .timedOut = error else { return XCTFail("expected .timedOut, got \(error)") }
        }
        // SIGTERM is ignored, so this only returns because SIGKILL follows.
        XCTAssertLessThan(Date().timeIntervalSince(started), 20, "the deadline must be enforced")
    }

    func testProcessExitingWhileADescendantHoldsStdoutStillReturns() async throws {
        // The child keeps the inherited stdout open for 30s. Waiting for EOF
        // would hang; the parent's own output is what the caller asked for.
        let path = try fixture("orphan.sh", "sleep 30 &\necho parent done\nexit 0\n")
        let started = Date()
        let result = try await runner.run(CommandInvocation(executable: path, timeout: 15))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput, "parent done\n")
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testCancellationStopsTheProcess() async throws {
        let path = try fixture("slow.sh", "sleep 30")
        let task = Task { try await runner.run(CommandInvocation(executable: path, timeout: 30)) }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch let error as CommandError {
            guard case .cancelled = error else { return XCTFail("expected .cancelled, got \(error)") }
        }
    }

    func testEnvironmentAndWorkingDirectoryAreApplied() async throws {
        let path = try fixture("env.sh", "printf '%s|%s' \"$MARMY_TEST\" \"$(pwd)\"")
        let result = try await runner.run(CommandInvocation(
            executable: path,
            environment: ["MARMY_TEST": "set", "PATH": "/usr/bin:/bin"],
            currentDirectory: directory.path))

        let fields = result.standardOutput.split(separator: "|").map(String.init)
        XCTAssertEqual(fields.first, "set")
        XCTAssertEqual(
            fields.last.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            directory.resolvingSymlinksInPath().path)
    }
}

/// How long an ordinary command takes to come back.
///
/// Every tmux command Marmy runs went through a third of a second of waiting:
/// a handle can report end of file more than once, each was counted, and the
/// count that says "everything has been read" was then never right.
final class CommandRunnerLatencyTests: XCTestCase {

    func testSmallCommandsComeBackAtOnce() async throws {
        let runner = SystemCommandRunner()
        let started = Date()
        for index in 0..<8 {
            let result = try await runner.run(CommandInvocation(
                executable: "/bin/echo", arguments: ["marmy \(index)"]))
            XCTAssertEqual(result.exitCode, 0)
            XCTAssertEqual(
                result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines),
                "marmy \(index)",
                "and what it printed is still all there")
        }
        let elapsed = Date().timeIntervalSince(started)

        // Waiting out the grace period on each would be about 2.4 seconds.
        XCTAssertLessThan(elapsed, 1.0, "eight echoes took \(elapsed)s")
    }

    func testOutputTooBigForOnePipeBufferStillArrivesWhole() async throws {
        let runner = SystemCommandRunner()
        let result = try await runner.run(CommandInvocation(
            executable: "/bin/sh",
            arguments: ["-c", "for i in $(seq 1 4000); do echo line $i; done"]))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.standardOutput.contains("line 1\n"))
        XCTAssertTrue(result.standardOutput.contains("line 4000"))
    }
}
