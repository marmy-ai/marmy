import AppKit
import Combine
import SwiftUI

@main
struct MacMarmyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let manager = AgentManager()
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        log("applicationDidFinishLaunching")
        createStatusItem()

        manager.$status
            .sink { [weak self] status in
                self?.log("agent status changed: \(status.label)")
                self?.updateStatusIcon()
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        manager.$sessions
            .sink { [weak self] _ in
                self?.rebuildMenu()
            }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        log("applicationWillTerminate")
        manager.stop()
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: 28)
        statusItem = item
        item.isVisible = true

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusMenu = menu
        item.menu = menu

        updateStatusIcon()
        rebuildMenu()
        log("created status item; button exists: \(item.button != nil)")
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else {
            log("status item has no button")
            return
        }

        button.toolTip = "MacMarmy"
        button.imagePosition = .imageOnly

        if case .error = manager.status {
            let image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "MacMarmy error")
            image?.isTemplate = true
            button.image = image
            button.title = image == nil ? "!" : ""
            return
        }

        if let image = marmyMenuBarIcon() {
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = "M"
            log("Marmy menu bar icon unavailable; using text fallback")
        }
    }

    private func marmyMenuBarIcon() -> NSImage? {
        let size = NSSize(width: 20, height: 20)
        let image = NSImage(size: size)
        image.lockFocus()

        guard let context = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return nil
        }

        NSApp.applicationIconImage.draw(
            in: NSRect(origin: .zero, size: size),
            from: .zero,
            operation: .copy,
            fraction: 1.0
        )

        guard let cgImage = context.makeImage() else {
            image.unlockFocus()
            return nil
        }
        image.unlockFocus()

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let bitmapContext = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        bitmapContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let red = pixels[offset]
                let green = pixels[offset + 1]
                let blue = pixels[offset + 2]
                let alpha = pixels[offset + 3]

                let isBackground = red < 70 && green < 70 && blue < 80
                if alpha < 20 || isBackground {
                    pixels[offset] = 0
                    pixels[offset + 1] = 0
                    pixels[offset + 2] = 0
                    pixels[offset + 3] = 0
                } else {
                    pixels[offset] = 0
                    pixels[offset + 1] = 0
                    pixels[offset + 2] = 0
                    pixels[offset + 3] = 255
                }
            }
        }

        guard let maskContext = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let maskCGImage = maskContext.makeImage() else {
            return nil
        }

        let template = NSImage(cgImage: maskCGImage, size: size)
        template.isTemplate = true
        return template
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard let menu = statusMenu else { return }
        menu.removeAllItems()

        let status = NSMenuItem(title: "Agent: \(manager.status.label)", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        addPairingItems(to: menu)
        menu.addItem(.separator())

        addSessionItems(to: menu)
        addAgentControlItems(to: menu)
        menu.addItem(.separator())

        addVoiceItems(to: menu)
        menu.addItem(.separator())

        let launchItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        launchItem.target = self
        launchItem.state = LaunchAtLoginController.isEnabled ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit MacMarmy", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func addPairingItems(to menu: NSMenu) {
        guard let info = manager.pairingInfo else {
            let missing = NSMenuItem(title: "No config found", action: nil, keyEquivalent: "")
            missing.isEnabled = false
            menu.addItem(missing)

            let hint = NSMenuItem(title: "Run: marmy-agent serve", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
            return
        }

        addDisabledItem("LAN: \(info.address)", to: menu)
        if let tsAddr = info.tailscaleAddress {
            addDisabledItem("Tailscale: \(tsAddr)", to: menu)
        }
        addDisabledItem("Token: \(info.token)", to: menu)

        addCopyItem(title: "Copy LAN Address", value: info.address, to: menu)
        if let tsAddr = info.tailscaleAddress {
            addCopyItem(title: "Copy Tailscale Address", value: tsAddr, to: menu)
        }
        addCopyItem(title: "Copy Token", value: info.token, to: menu)
    }

    private func addSessionItems(to menu: NSMenu) {
        guard manager.status == .running, !manager.sessions.isEmpty else { return }

        let submenu = NSMenu()
        for session in manager.sessions {
            var title = session.name
            if session.unread {
                title += " - unread"
            }
            if session.attached {
                title += " - attached"
            }

            let item = NSMenuItem(title: title, action: #selector(openSession(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = session.name
            submenu.addItem(item)
        }

        let sessionsItem = NSMenuItem(title: "Sessions (\(manager.sessions.count))", action: nil, keyEquivalent: "")
        sessionsItem.submenu = submenu
        menu.addItem(sessionsItem)
        menu.addItem(.separator())
    }

    private func addAgentControlItems(to menu: NSMenu) {
        let title = (manager.status == .running || manager.status == .starting) ? "Stop Agent" : "Start Agent"
        let action = (manager.status == .running || manager.status == .starting) ? #selector(stopAgent) : #selector(startAgent)
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)

        let reload = NSMenuItem(title: "Reload Config", action: #selector(reloadConfig), keyEquivalent: "")
        reload.target = self
        menu.addItem(reload)
    }

    private func addVoiceItems(to menu: NSMenu) {
        if let info = manager.pairingInfo, let key = info.geminiApiKey, !key.isEmpty {
            addDisabledItem("Voice Mode: Enabled", to: menu)
        } else {
            let setup = NSMenuItem(title: "Set Up Voice Mode...", action: #selector(promptForGeminiKey), keyEquivalent: "")
            setup.target = self
            menu.addItem(setup)
        }
    }

    private func addDisabledItem(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addCopyItem(title: String, value: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: #selector(copyRepresentedString(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = value
        menu.addItem(item)
    }

    @objc private func copyRepresentedString(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func openSession(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        let sanitized = name.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !sanitized.isEmpty else { return }

        let script = "tell application \"Terminal\" to do script \"tmux attach-session -t \(sanitized)\""
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script, "-e", "tell application \"Terminal\" to activate"]
        try? proc.run()
    }

    @objc private func startAgent() {
        manager.start()
        rebuildMenu()
    }

    @objc private func stopAgent() {
        manager.stop()
        rebuildMenu()
    }

    @objc private func reloadConfig() {
        manager.reloadConfig()
        rebuildMenu()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        _ = LaunchAtLoginController.setEnabled(sender.state != .on)
        rebuildMenu()
    }

    @objc private func promptForGeminiKey() {
        let alert = NSAlert()
        alert.messageText = "Set Up Voice Mode"
        alert.informativeText = "Enter your Gemini API key to enable voice calls.\n\nYour key is stored locally on this machine in:\n~/Library/Application Support/marmy/config.toml\n\nIt is never sent anywhere except directly to Google's API.\n\nGet a key at: https://aistudio.google.com/apikey"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.placeholderString = "Paste Gemini API key here"
        alert.accessoryView = input

        NSApp.activate(ignoringOtherApps: true)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let key = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                ConfigReader.setGeminiApiKey(key)
                manager.stop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.manager.reloadConfig()
                    self.manager.start()
                }
            }
        }
    }

    @objc private func quit() {
        manager.stop()
        NSApplication.shared.terminate(nil)
    }

    private func log(_ message: String) {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MacMarmy.log")
        let line = "\(Date()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: path.path),
           let handle = try? FileHandle(forWritingTo: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: path)
        }
    }
}
