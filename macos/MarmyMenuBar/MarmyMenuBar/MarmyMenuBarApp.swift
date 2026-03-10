import SwiftUI

@main
struct MarmyMenuBarApp: App {
    @StateObject private var manager = AgentManager()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(manager: manager)
        } label: {
            if case .error = manager.status {
                Image(systemName: "exclamationmark.triangle")
            } else {
                Image("MenuBarIcon")
                    .renderingMode(.template)
            }
        }
        .menuBarExtraStyle(.menu)
    }
}
