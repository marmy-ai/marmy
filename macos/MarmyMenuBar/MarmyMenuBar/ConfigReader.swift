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
        let tailscaleIP = detectTailscaleIP()

        let geminiKey = extractValue(from: content, key: "gemini_api_key")

        return PairingInfo(hostname: hostname, localIP: localIP, port: port, token: token, tailscaleIP: tailscaleIP, geminiApiKey: geminiKey)
    }

    static func setGeminiApiKey(_ key: String) {
        let path = configPath
        var content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""

        // Check if [voice] section exists
        if content.contains("[voice]") {
            // Replace or add gemini_api_key under [voice]
            let pattern = #"(?m)^(\s*gemini_api_key\s*=\s*).*$"#
            if let regex = try? NSRegularExpression(pattern: pattern),
               regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)) != nil {
                content = regex.stringByReplacingMatches(in: content, range: NSRange(content.startIndex..., in: content), withTemplate: "gemini_api_key = \"\(key)\"")
            } else {
                content = content.replacingOccurrences(of: "[voice]", with: "[voice]\ngemini_api_key = \"\(key)\"")
            }
        } else {
            content += "\n\n[voice]\ngemini_api_key = \"\(key)\"\n"
        }

        try? content.write(toFile: path, atomically: true, encoding: .utf8)
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

    /// Tailscale assigns addresses from the CGNAT range 100.64.0.0/10, so the
    /// tailnet IP can be read straight off the network interfaces. This must
    /// not depend on finding the `tailscale` CLI: Finder-launched apps get a
    /// minimal PATH without Homebrew or Tailscale.app's binary, which is why
    /// the pairing QR used to silently fall back to LAN-only.
    private static func detectTailscaleIP() -> String? {
        if let ip = tailscaleIPFromInterfaces() {
            return ip
        }
        // Fallback: ask the CLI at its known install locations.
        let candidates = [
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "/opt/homebrew/bin/tailscale",
            "/usr/local/bin/tailscale",
        ]
        for binary in candidates where FileManager.default.isExecutableFile(atPath: binary) {
            if let ip = runTailscaleIP(binary: binary) {
                return ip
            }
        }
        return nil
    }

    private static func tailscaleIPFromInterfaces() -> String? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            cursor = ifa.pointee.ifa_next

            guard (ifa.pointee.ifa_flags & UInt32(IFF_UP)) != 0,
                  let sa = ifa.pointee.ifa_addr,
                  sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }

            var sin = sockaddr_in()
            memcpy(&sin, sa, MemoryLayout<sockaddr_in>.size)
            let host = UInt32(bigEndian: sin.sin_addr.s_addr)
            // 100.64.0.0/10
            guard (host & 0xFFC0_0000) == 0x6440_0000 else { continue }

            var addr = sin.sin_addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            return String(cString: buffer)
        }
        return nil
    }

    private static func runTailscaleIP(binary: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = ["ip", "-4"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let ip = String(data: data, encoding: .utf8)?
                .split(separator: "\n")
                .first
                .map { $0.trimmingCharacters(in: .whitespaces) }
            return (ip?.isEmpty == false) ? ip : nil
        } catch {
            return nil
        }
    }
}
