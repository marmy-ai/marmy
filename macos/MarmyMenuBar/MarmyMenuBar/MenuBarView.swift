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
            Text("Address: \(info.address)")
                .font(.system(.body, design: .monospaced))
            Text("Token: \(info.token)")
                .font(.system(.body, design: .monospaced))

            Button("Copy Address") {
                copyToClipboard(info.address)
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

        // Controls
        if manager.status == .running || manager.status == .starting {
            Button("Stop Agent") { manager.stop() }
        } else {
            Button("Start Agent") { manager.start() }
        }

        Button("Reload Config") { manager.reloadConfig() }

        Divider()

        Toggle("Launch at Login", isOn: $launchAtLogin)
            .onChange(of: launchAtLogin) { newValue in
                setLaunchAtLogin(newValue)
            }

        Divider()

        Button("Quit Marmy") {
            manager.stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApplication.shared.terminate(nil)
            }
        }
        .keyboardShortcut("q")
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
