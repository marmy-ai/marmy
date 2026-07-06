import AppKit
import SwiftUI
import CoreImage.CIFilterBuiltins

// MARK: - Shared Terminal launcher

enum TerminalLauncher {
    static func openSession(_ name: String) {
        // Sanitize session name (agent already validates: alphanumeric, underscore, hyphen).
        let sanitized = name.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !sanitized.isEmpty else { return }

        // Use osascript subprocess instead of NSAppleScript to avoid silent permission failures.
        let script = "tell application \"Terminal\" to do script \"tmux attach-session -t \(sanitized)\""
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script, "-e", "tell application \"Terminal\" to activate"]
        try? proc.run()
    }
}

// MARK: - Auxiliary window management

// The app's only scene is a MenuBarExtra(.menu), which can't host images or
// rich views — so the QR pairing panel and the agents dashboard open as
// plain NSWindows created on demand and reused while open.
@MainActor
final class AuxWindows {
    static let shared = AuxWindows()
    private var windows: [String: NSWindow] = [:]
    private var closeObservers: [String: NSObjectProtocol] = [:]

    func show<Content: View>(
        id: String,
        title: String,
        width: CGFloat,
        height: CGFloat,
        resizable: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        if let existing = windows[id] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: AnyView(content()))
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        var mask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { mask.insert(.resizable) }
        window.styleMask = mask
        window.setContentSize(NSSize(width: width, height: height))
        window.isReleasedWhenClosed = false
        window.center()
        windows[id] = window

        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            Task { @MainActor in
                AuxWindows.shared.windows.removeValue(forKey: id)
                if let t = AuxWindows.shared.closeObservers.removeValue(forKey: id) {
                    NotificationCenter.default.removeObserver(t)
                }
            }
        }
        closeObservers[id] = token

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - QR pairing

struct PairingQRView: View {
    @ObservedObject var manager: AgentManager

    var body: some View {
        VStack(spacing: 14) {
            if let info = manager.pairingInfo {
                Text("Scan with the Marmy app")
                    .font(.headline)

                if let qr = Self.qrImage(for: Self.payload(info)) {
                    Image(nsImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 220, height: 220)
                        .padding(10)
                        .background(Color.white)
                        .cornerRadius(10)
                        .accessibilityLabel("Pairing QR code")
                } else {
                    Text("Could not generate QR code")
                        .foregroundColor(.secondary)
                }

                VStack(spacing: 3) {
                    if let tsAddr = info.tailscaleAddress {
                        Text("Tailscale: \(tsAddr)")
                    }
                    Text("LAN: \(info.address)")
                }
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)

                Text("The code contains this machine's addresses and auth token.\nAnyone who scans it can control your sessions.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("No config found")
                    .font(.headline)
                Text("Start the agent once to generate a token, then reopen this window.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(width: 320)
    }

    // JSON payload the iOS app scans. Tailscale address first: the tailnet IP
    // is stable across networks, so the app should prefer it when present.
    static func payload(_ info: PairingInfo) -> String {
        var addrs: [String] = []
        if let tsAddr = info.tailscaleAddress {
            addrs.append(tsAddr)
        }
        addrs.append(info.address)
        let obj: [String: Any] = [
            "marmy": 1,
            "name": info.hostname,
            "addrs": addrs,
            "token": info.token,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func qrImage(for string: String) -> NSImage? {
        guard !string.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

// MARK: - Agents dashboard

struct DashboardView: View {
    @ObservedObject var manager: AgentManager

    var body: some View {
        Group {
            if manager.status != .running {
                VStack(spacing: 10) {
                    Text("\(manager.status.icon) Agent: \(manager.status.label)")
                        .font(.headline)
                    if manager.status == .stopped || manager.isError {
                        Button("Start Agent") { manager.start() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if manager.sessions.isEmpty {
                VStack(spacing: 6) {
                    Text("No sessions running")
                        .font(.headline)
                    Text("Sessions started from the phone or via tmux show up here.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(manager.sessions.count) session\(manager.sessions.count == 1 ? "" : "s") — click one to open it in Terminal")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    Divider()
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(manager.sessions) { session in
                                SessionRow(session: session)
                            }
                        }
                        .padding(8)
                    }
                }
            }
        }
        .frame(minWidth: 400, minHeight: 320)
    }
}

private struct SessionRow: View {
    let session: MarmySession
    @State private var hovering = false

    var body: some View {
        Button(action: { TerminalLauncher.openSession(session.name) }) {
            HStack(spacing: 10) {
                Circle()
                    .fill(session.unread ? Color.orange : Color.green)
                    .frame(width: 8, height: 8)
                    .help(session.unread ? "Has unread output" : "Idle")
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.name)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.medium)
                    if !session.windows.isEmpty {
                        Text(session.windows.joined(separator: " · "))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if session.attached {
                    Image(systemName: "desktopcomputer")
                        .foregroundColor(.secondary)
                        .help("Attached in a terminal")
                }
                Image(systemName: "arrow.up.forward.square")
                    .foregroundColor(hovering ? .primary : Color.secondary.opacity(0.5))
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(hovering ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
