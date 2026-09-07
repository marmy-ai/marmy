import Foundation

/// One subprocess call: what to run and how to feed it.
public struct CommandInvocation: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    /// `nil` inherits this process's environment.
    public var environment: [String: String]?
    public var standardInput: Data?
    public var currentDirectory: String?
    public var timeout: TimeInterval

    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        standardInput: Data? = nil,
        currentDirectory: String? = nil,
        timeout: TimeInterval = 15
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.standardInput = standardInput
        self.currentDirectory = currentDirectory
        self.timeout = timeout
    }
}

public struct CommandResult: Sendable, Equatable {
    public var exitCode: Int32
    /// Raw bytes, because tmux formats are parsed by byte length and a lossy
    /// string conversion would move the field boundaries.
    public var standardOutputData: Data
    public var standardErrorData: Data

    public init(exitCode: Int32, standardOutputData: Data, standardErrorData: Data = Data()) {
        self.exitCode = exitCode
        self.standardOutputData = standardOutputData
        self.standardErrorData = standardErrorData
    }

    public init(exitCode: Int32, standardOutput: String = "", standardError: String = "") {
        self.init(
            exitCode: exitCode,
            standardOutputData: Data(standardOutput.utf8),
            standardErrorData: Data(standardError.utf8))
    }

    public var standardOutput: String { String(decoding: standardOutputData, as: UTF8.self) }
    public var standardError: String { String(decoding: standardErrorData, as: UTF8.self) }

    public var isSuccess: Bool { exitCode == 0 }

    /// stderr if there is any, otherwise stdout — whichever actually explains a failure.
    public var failureText: String {
        let error = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        if !error.isEmpty { return error }
        return standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum CommandError: Error, CustomStringConvertible {
    case launchFailed(executable: String, detail: String)
    case inputNotDelivered(executable: String, detail: String)
    case timedOut(executable: String, seconds: TimeInterval)
    case cancelled

    public var description: String {
        switch self {
        case .launchFailed(let executable, let detail):
            return "Could not run \(executable): \(detail)"
        case .inputNotDelivered(let executable, let detail):
            return "\(executable) did not read all of its input: \(detail)"
        case .timedOut(let executable, let seconds):
            return "\(executable) did not finish within \(Int(seconds))s."
        case .cancelled:
            return "The command was cancelled."
        }
    }
}

/// Injection point for everything that shells out. Tests substitute a fake so
/// no test ever needs a real tmux server.
public protocol CommandRunning: Sendable {
    func run(_ invocation: CommandInvocation) async throws -> CommandResult
}

/// Runs short-lived processes off the main thread.
///
/// stdout and stderr are drained on their own queues while the process runs, so
/// a chatty command can never fill a pipe and deadlock, and the call is a plain
/// `await` for the UI.
public struct SystemCommandRunner: CommandRunning {
    public init() {}

    public func run(_ invocation: CommandInvocation) async throws -> CommandResult {
        let execution = ProcessExecution(invocation)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                execution.start(continuation)
            }
        } onCancel: {
            execution.cancel()
        }
    }
}

/// Bridges one `Process` to one continuation, resuming exactly once.
///
/// Every state change happens on one serial queue, so output buffers, the exit
/// status, the deadline, and cancellation can never race. Reads use readability
/// handlers rather than blocking reads, so no thread is ever stuck on a pipe a
/// descendant is holding open.
private final class ProcessExecution: @unchecked Sendable {
    /// A write to a pipe whose reader has exited must not kill this process.
    private static let ignoreSIGPIPE: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    /// How long to wait for the last bytes after the process exits. A descendant
    /// can hold the pipe open forever, and its output is not ours to wait for.
    private static let readerGrace: TimeInterval = 0.3
    /// After the deadline: SIGTERM, then SIGKILL, then give up regardless.
    private static let terminateGrace: TimeInterval = 2
    private static let forceFinishGrace: TimeInterval = 3

    private let invocation: CommandInvocation
    private let process = Process()
    private let queue = DispatchQueue(label: "ai.marmy.command")
    private let writeQueue = DispatchQueue(label: "ai.marmy.command.stdin")

    private var continuation: CheckedContinuation<CommandResult, Error>?
    private var stdoutData = Data()
    private var stderrData = Data()
    private var openReaders = 0
    private var processExited = false
    private var exitStatus: Int32 = 0
    private var failure: Error?
    private var cancelRequested = false
    private var started = false
    private var stdinSettled = true
    private var readerGraceAttempts = 0
    private var finished = false
    private var timers: [DispatchSourceTimer] = []
    private var readHandles: [FileHandle] = []
    /// Handles that have already reported end of file.
    private var eofReaders: Set<ObjectIdentifier> = []

    init(_ invocation: CommandInvocation) {
        _ = Self.ignoreSIGPIPE
        self.invocation = invocation
    }

    func start(_ continuation: CheckedContinuation<CommandResult, Error>) {
        queue.async { self.startOnQueue(continuation) }
    }

    func cancel() {
        queue.async {
            self.cancelRequested = true
            if self.failure == nil { self.failure = CommandError.cancelled }
            guard self.started else {
                // Cancelled before the process was launched: nothing to kill. If
                // start has not run yet there is no continuation to resume, and
                // `finishIfPossible` leaves the execution untouched so the
                // eventual start resumes it immediately.
                self.finishIfPossible(force: true)
                return
            }
            self.escalateTermination()
        }
    }

    // MARK: - Queue-confined work

    private func startOnQueue(_ continuation: CheckedContinuation<CommandResult, Error>) {
        self.continuation = continuation
        guard !cancelRequested else {
            finishIfPossible(force: true)
            return
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe
        if let environment = invocation.environment { process.environment = environment }
        if let directory = invocation.currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
        }

        readHandles = [outPipe.fileHandleForReading, errPipe.fileHandleForReading]
        openReaders = 2
        drain(outPipe.fileHandleForReading) { self.stdoutData.append($0) }
        drain(errPipe.fileHandleForReading) { self.stderrData.append($0) }

        // Installed before launch so a process that exits immediately is never missed.
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            let status = process.terminationStatus
            self.queue.async {
                self.processExited = true
                self.exitStatus = status
                // The process is done; its own output has been written. Anything
                // still holding the pipe open is a descendant we do not wait for.
                self.scheduleReaderGrace()
                self.finishIfPossible()
            }
        }

        do {
            try process.run()
            started = true
        } catch {
            teardownReaders()
            try? inPipe.fileHandleForWriting.close()
            failure = CommandError.launchFailed(
                executable: invocation.executable, detail: error.localizedDescription)
            finishIfPossible(force: true)
            return
        }

        stdinSettled = (invocation.standardInput?.isEmpty ?? true)
        writeStandardInput(to: inPipe.fileHandleForWriting)
        scheduleTimer(after: invocation.timeout) { [weak self] in
            guard let self, !self.processExited else { return }
            if self.failure == nil {
                self.failure = CommandError.timedOut(
                    executable: self.invocation.executable, seconds: self.invocation.timeout)
            }
            self.escalateTermination()
        }
    }

    private func drain(_ handle: FileHandle, append: @escaping (Data) -> Void) {
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            self.queue.async {
                guard !self.finished else { return }
                if data.isEmpty {
                    // End of file, counted once per handle. The handler runs on
                    // its own queue and is cleared on this one, so more empty
                    // reads can arrive in between; counting each of them took
                    // `openReaders` below zero, the "everything is read" test
                    // never matched, and every single command waited out the
                    // grace period instead — a third of a second, on all of them.
                    guard self.eofReaders.insert(ObjectIdentifier(handle)).inserted else { return }
                    handle.readabilityHandler = nil
                    self.openReaders -= 1
                    self.finishIfPossible()
                } else {
                    append(data)
                }
            }
        }
    }

    private func writeStandardInput(to handle: FileHandle) {
        let input = invocation.standardInput
        guard let input, !input.isEmpty else {
            writeQueue.async { try? handle.close() }
            return
        }
        writeQueue.async { [weak self] in
            var detail: String?
            do {
                try handle.write(contentsOf: input)
            } catch {
                // The reader went away mid-write: the command did not receive
                // everything Marmy sent, so it must not be reported as sent.
                detail = Self.isBrokenPipe(error)
                    ? "the command closed its input before all of it was written"
                    : error.localizedDescription
            }
            try? handle.close()
            self?.queue.async {
                guard let self else { return }
                self.stdinSettled = true
                if let detail, self.failure == nil {
                    self.failure = CommandError.inputNotDelivered(
                        executable: self.invocation.executable, detail: detail)
                }
                self.finishIfPossible()
            }
        }
    }

    /// Waits briefly for the last bytes after the process exits, and for the
    /// stdin write to settle, before giving up on either.
    private func scheduleReaderGrace() {
        scheduleTimer(after: Self.readerGrace) { [weak self] in
            guard let self else { return }
            self.readerGraceAttempts += 1
            if self.stdinSettled {
                self.finishIfPossible(force: true)
            } else if self.readerGraceAttempts >= 5 {
                // The write never settled, so what the command received is
                // unknown. Reporting success here would claim a message was
                // delivered when it may not have been.
                if self.failure == nil {
                    self.failure = CommandError.inputNotDelivered(
                        executable: self.invocation.executable,
                        detail: "the input was still being written when the command exited")
                }
                self.finishIfPossible(force: true)
            } else {
                self.scheduleReaderGrace()
            }
        }
    }

    /// Foundation wraps the POSIX error, so the chain has to be walked.
    private static func isBrokenPipe(_ error: Error) -> Bool {
        var pending: [NSError] = [error as NSError]
        while let current = pending.popLast() {
            if current.domain == NSPOSIXErrorDomain && current.code == Int(EPIPE) { return true }
            if let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError {
                pending.append(underlying)
            }
        }
        return false
    }

    /// SIGTERM, then SIGKILL for a process that ignores it, then finish anyway.
    private func escalateTermination() {
        guard started, !finished else {
            finishIfPossible(force: true)
            return
        }
        if process.isRunning { process.terminate() }
        scheduleTimer(after: Self.terminateGrace) {
            if self.process.isRunning { kill(self.process.processIdentifier, SIGKILL) }
        }
        scheduleTimer(after: Self.forceFinishGrace) { self.finishIfPossible(force: true) }
    }

    private func scheduleTimer(after seconds: TimeInterval, _ body: @escaping () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler { [weak self] in
            guard let self, !self.finished else { return }
            body()
        }
        timers.append(timer)
        timer.resume()
    }

    private func finishIfPossible(force: Bool = false) {
        guard !finished else { return }
        // Nothing to resume yet. Marking the execution finished here would make
        // a cancellation that lands before `start` hang the caller forever.
        guard let pending = continuation else { return }
        guard force || (processExited && openReaders == 0 && stdinSettled) else { return }
        finished = true
        continuation = nil

        for timer in timers { timer.cancel() }
        timers.removeAll()
        teardownReaders()

        if let failure {
            pending.resume(throwing: failure)
            return
        }
        pending.resume(returning: CommandResult(
            exitCode: processExited ? exitStatus : -1,
            standardOutputData: stdoutData,
            standardErrorData: stderrData))
    }

    private func teardownReaders() {
        for handle in readHandles {
            handle.readabilityHandler = nil
            try? handle.close()
        }
        readHandles.removeAll()
        openReaders = 0
    }
}
