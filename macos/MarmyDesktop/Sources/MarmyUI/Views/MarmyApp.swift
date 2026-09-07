import MarmyCore
import MarmyRuntime
import SwiftUI

/// The app itself.
///
/// Everything it needs is built once here: the saved workspace, the tmux
/// runtime, terminals, and dictation.
public struct MarmyApp: App {
    @State private var env: AppEnvironment

    public init() {
        let store = WorkspaceStore(directoryURL: WorkspaceStore.defaultDirectory())
        let prepared = MarmyApp.prepareRuntime()
        let model = AppModel(
            store: store,
            runtime: prepared.runtime,
            startupFailure: prepared.failure)
        _env = State(initialValue: AppEnvironment(model: model))
    }

    /// Builds the runtime, or explains exactly why it could not be built.
    ///
    /// A ledger that will not load is never quietly replaced with a scratch one:
    /// that would lose which sessions Marmy owns. The app opens read-only
    /// instead, with the real error in front of the user.
    static func prepareRuntime() -> (runtime: AgentRuntime, failure: String?) {
        let server = TmuxServerAddress.fromEnvironment()
        let locator = ExecutableLocator()
        let runtimeStore = RuntimeStore(directoryURL: RuntimeStore.defaultDirectory())

        var failure: String?
        let tmuxPath: String
        if let path = locator.locate("tmux") {
            tmuxPath = path
        } else {
            tmuxPath = "/opt/homebrew/bin/tmux"
            failure = "tmux was not found. Marmy runs every agent in tmux, so install it — "
                + "\u{22}brew install tmux\u{22} — or add the folder containing it to your PATH, "
                + "then reopen Marmy Desktop. Looked in: \(locator.searchDirectories.joined(separator: ", "))."
        }
        let tmux = TmuxClient(executablePath: tmuxPath, server: server, runner: SystemCommandRunner())

        do {
            return (try AgentRuntime(tmux: tmux, locator: locator, store: runtimeStore), failure)
        } catch {
            // Look but do not touch: the real ledger is kept exactly as it is,
            // and every action that would change anything is refused with this
            // reason until the file is fixed.
            let message = "Marmy's record of running agents could not be read, so it will not start, "
                + "attach, or message anything until that is fixed. The file is at "
                + "\(runtimeStore.ledgerURL.path).\n\(error)"
            let runtime = AgentRuntime(
                readOnly: message, tmux: tmux, locator: locator, store: runtimeStore)
            return (runtime, [failure, message].compactMap { $0 }.joined(separator: "\n\n"))
        }
    }

    public var body: some Scene {
        // One window: the terminals are real tmux clients owned by this
        // environment, and a second window would take them out of the first.
        Window("Marmy Desktop", id: "marmy.main") {
            RootView(env: env)
                .frame(minWidth: 960, minHeight: 640)
                .onAppear { env.startMonitoring() }
                .onDisappear { env.shutDown() }
                .environment(\.controlActiveState, .key)
        }
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unified)
        .commands { commands }
    }

    @CommandsBuilder
    private var commands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Team…") { env.showsNewTeamSheet = true }
                .keyboardShortcut("n", modifiers: [.command])
        }
        CommandMenu("Agents") {
            Button("Work View") { env.model.mode = .work }
                .keyboardShortcut("1", modifiers: [.command])
            Button("Topology View") { env.model.mode = .topology }
                .keyboardShortcut("2", modifiers: [.command])
            Divider()
            Button("Next Peer") { env.navigate(.nextPeer) }
            Button("Previous Peer") { env.navigate(.previousPeer) }
            // No key equivalents here: the work-area monitor owns Command-Up
            // and Command-Down so they keep meaning "move the caret" while the
            // user is typing.
            Button("Go to Manager") { env.navigate(.parent) }
            Button("Go to Report") { env.navigate(.child) }
            Divider()
            Button("Launch Team") { Task { await env.model.launchSelectedTeam() } }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Templates…") { env.showsTemplates = true }
        }
        CommandGroup(replacing: .help) {
            Button("Marmy Keyboard Shortcuts") { env.showsShortcuts = true }
        }
    }
}
