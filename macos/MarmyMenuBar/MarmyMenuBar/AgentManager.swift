import Foundation
import Combine

struct MarmySession: Decodable, Identifiable {
    let id: String
    let name: String
    let windows: [String]
    let attached: Bool
    let unread: Bool
}

private struct SessionsResponse: Decodable {
    let sessions: [MarmySession]
}

enum AgentStatus: Equatable {
    case stopped
    case starting
    case running
    case error(String)

    var label: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .running: return "Running"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    var icon: String {
        switch self {
        case .running: return "🟢"
        case .starting: return "🟡"
        case .stopped: return "⚪"
        case .error: return "🔴"
        }
    }
}

@MainActor
final class AgentManager: ObservableObject {
    @Published var status: AgentStatus = .stopped
    @Published var pairingInfo: PairingInfo?
    @Published var sessions: [MarmySession] = []

    private var process: Process?
    private var healthTimer: Timer?
    private var isStopping = false

    init() {
        reloadConfig()
        start()
    }

    func reloadConfig() {
        pairingInfo = ConfigReader.read()
    }

    // MARK: - Start / Stop

    func start() {
        guard status == .stopped || isError else { return }
        status = .starting
        isStopping = false

        let agentPath = agentBinaryPath()
        guard FileManager.default.fileExists(atPath: agentPath) else {
            status = .error("Binary not found at \(agentPath)")
            return
        }

        // Launch on a background thread to avoid blocking main actor
        let path = agentPath
        let env = buildEnv()
        DispatchQueue.global().async { [weak self] in
            // Kill stale agents first
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            kill.arguments = ["-f", "marmy-agent serve"]
            try? kill.run()
            kill.waitUntilExit()
            Thread.sleep(forTimeInterval: 1.0)

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: path)
            proc.arguments = ["serve"]
            proc.environment = env

            // Write output to log file — never use Pipe (causes deadlock)
            let logPath = NSHomeDirectory() + "/Library/Logs/marmy-agent.log"
            FileManager.default.createFile(atPath: logPath, contents: nil)
            if let logFile = FileHandle(forWritingAtPath: logPath) {
                proc.standardOutput = logFile
                proc.standardError = logFile
            }

            proc.terminationHandler = { [weak self] p in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    self.stopHealthCheck()
                    if self.isStopping {
                        self.status = .stopped
                    } else if p.terminationStatus != 0 {
                        self.status = .error("Exit code \(p.terminationStatus)")
                    } else {
                        self.status = .stopped
                    }
                    self.process = nil
                }
            }

            do {
                try proc.run()
                Task { @MainActor [weak self] in
                    self?.process = proc
                    self?.startHealthCheck()
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.status = .error(error.localizedDescription)
                }
            }
        }
    }

    func stop() {
        guard let proc = process, proc.isRunning else {
            status = .stopped
            return
        }
        isStopping = true
        status = .stopped
        sessions = []
        stopHealthCheck()
        proc.terminate()

        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if proc.isRunning {
                proc.interrupt()
            }
        }
    }

    func toggle() {
        if status == .stopped || isError {
            start()
        } else {
            stop()
        }
    }

    var isError: Bool {
        if case .error = status { return true }
        return false
    }

    // MARK: - Health Check

    private func startHealthCheck() {
        healthTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.checkHealth()
            }
        }
        Task { await checkHealth() }
    }

    private func stopHealthCheck() {
        healthTimer?.invalidate()
        healthTimer = nil
    }

    private func checkHealth() async {
        guard let info = pairingInfo, process?.isRunning == true else { return }

        let urlString = "http://127.0.0.1:\(info.port)/api/sessions"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(info.token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 3

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                if status != .running {
                    status = .running
                    reloadConfig()
                }
                // Parse sessions from response
                if let decoded = try? JSONDecoder().decode(SessionsResponse.self, from: data) {
                    sessions = decoded.sessions.filter { $0.name != "_marmy_ctrl" }
                }
            } else {
                if status == .running { status = .starting }
                sessions = []
            }
        } catch {
            if status == .running { status = .starting }
            sessions = []
        }
    }

    // MARK: - Helpers

    private func agentBinaryPath() -> String {
        Bundle.main.bundlePath + "/Contents/MacOS/marmy-agent"
    }

    private func buildEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        env["TERM"] = env["TERM"] ?? "xterm-256color"
        env["HOME"] = env["HOME"] ?? NSHomeDirectory()
        return env
    }
}
