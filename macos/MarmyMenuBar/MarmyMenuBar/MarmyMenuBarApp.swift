import SwiftUI

@main
struct MarmyMenuBarApp: App {
    @StateObject private var manager = AgentManager()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(manager: manager)
        } label: {
            Image(systemName: menuBarIcon)
        }
        .menuBarExtraStyle(.menu)
    }

    private var menuBarIcon: String {
        switch manager.status {
        case .running: return "terminal.fill"
        case .starting: return "terminal"
        case .stopped: return "terminal"
        case .error: return "exclamationmark.triangle"
        }
    }
}
