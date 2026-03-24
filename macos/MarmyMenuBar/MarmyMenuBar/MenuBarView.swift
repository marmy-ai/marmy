import SwiftUI
import ServiceManagement

struct MenuBarView: View {
    @ObservedObject var manager: AgentManager
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        // Status
        Text("\(manager.status.icon) Agent: \(manager.status.label)")

        Divider()

        // Pairing info
        if let info = manager.pairingInfo {
            Text("LAN: \(info.address)")
                .font(.system(.body, design: .monospaced))
            if let tsAddr = info.tailscaleAddress {
                Text("Tailscale: \(tsAddr)")
                    .font(.system(.body, design: .monospaced))
            }
            Text("Token: \(info.token)")
                .font(.system(.body, design: .monospaced))

            Button("Copy LAN Address") {
                copyToClipboard(info.address)
            }
            if let tsAddr = info.tailscaleAddress {
                Button("Copy Tailscale Address") {
                    copyToClipboard(tsAddr)
                }
            }
            Button("Copy Token") {
                copyToClipboard(info.token)
            }
        } else {
            Text("No config found")
                .foregroundColor(.secondary)
            Text("Run: marmy-agent serve")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
        }

        Divider()

        // Sessions
        if manager.status == .running && !manager.sessions.isEmpty {
            Text("Sessions (\(manager.sessions.count))")
                .foregroundColor(.secondary)
                .font(.system(.caption))
            ForEach(manager.sessions) { session in
                Button(action: { openSession(session.name) }) {
                    HStack {
                        Text(session.name)
                        Spacer()
                        if session.unread {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 6))
                                .foregroundColor(.blue)
                        }
                        if session.attached {
                            Image(systemName: "desktopcomputer")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            Divider()
        }

        // Controls
        if manager.status == .running || manager.status == .starting {
            Button("Stop Agent") { manager.stop() }
        } else {
            Button("Start Agent") { manager.start() }
        }

        Button("Reload Config") { manager.reloadConfig() }

        Divider()

        // Voice mode
        if let info = manager.pairingInfo, let key = info.geminiApiKey, !key.isEmpty {
            Text("Voice Mode: Enabled")
                .foregroundColor(.secondary)
        } else {
            Button("Set Up Voice Mode...") {
                promptForGeminiKey()
            }
        }

        Divider()

        Toggle("Launch at Login", isOn: $launchAtLogin)
            .onChange(of: launchAtLogin) { newValue in
                setLaunchAtLogin(newValue)
            }

        Divider()

        Button("Quit MacMarmy") {
            manager.stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApplication.shared.terminate(nil)
            }
        }
        .keyboardShortcut("q")
    }

    private func promptForGeminiKey() {
        let alert = NSAlert()
        alert.messageText = "Set Up Voice Mode"
        alert.informativeText = "Enter your Gemini API key to enable voice calls.\n\nYour key is stored locally on this machine in:\n~/Library/Application Support/marmy/config.toml\n\nIt is never sent anywhere except directly to Google's API.\n\nGet a key at: https://aistudio.google.com/apikey"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.placeholderString = "Paste Gemini API key here"
        alert.accessoryView = input

        // Bring app to front for the dialog
        NSApp.activate(ignoringOtherApps: true)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let key = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                ConfigReader.setGeminiApiKey(key)
                manager.stop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    manager.reloadConfig()
                    manager.start()
                }
            }
        }
    }

    private func openSession(_ name: String) {
        // Sanitize session name to prevent AppleScript injection.
        // tmux session names are already validated by the agent (alphanumeric, underscore, hyphen).
        let sanitized = name.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !sanitized.isEmpty else { return }
        let script = """
        tell application "Terminal"
            activate
            do script "tmux attach-session -t \(sanitized)"
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
