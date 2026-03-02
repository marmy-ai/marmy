import Foundation

struct ConfigReader {
    static let configPath: String = {
        // Match Rust dirs::config_dir() which returns ~/Library/Application Support on macOS
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("marmy/config.toml").path
    }()

    static func read() -> PairingInfo? {
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return nil
        }

        let port = extractValue(from: content, key: "port").flatMap { UInt16($0) } ?? 9876
        let token = extractValue(from: content, key: "token") ?? ""

        guard !token.isEmpty else { return nil }

        let hostname = ProcessInfo.processInfo.hostName
        let localIP = detectLocalIP() ?? "127.0.0.1"

        return PairingInfo(hostname: hostname, localIP: localIP, port: port, token: token)
    }

    private static func extractValue(from content: String, key: String) -> String? {
        // Match key = value or key = "value" in TOML
        let pattern = #"(?m)^\s*"# + NSRegularExpression.escapedPattern(for: key) + #"\s*=\s*"?([^"\n]+)"?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
              let range = Range(match.range(at: 1), in: content) else {
            return nil
        }
        let value = String(content[range]).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// Detect the local IP by connecting a UDP socket to a public address.
    /// Same approach as the Rust agent's `get_local_ips()`.
    private static func detectLocalIP() -> String? {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return nil }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = CFSwapInt16HostToBig(80)
        inet_pton(AF_INET, "8.8.8.8", &addr.sin_addr)

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { return nil }

        var localAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &localAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(sock, sockPtr, &len)
            }
        }
        guard nameResult == 0 else { return nil }

        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &localAddr.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buffer)
    }
}
