import MarmyCore
import SwiftUI

/// A node id a sheet can be presented for.
struct IdentifiedNode: Identifiable {
    let id: UUID
}

/// The window: teams on the left, the selected agent in the middle.
public struct RootView: View {
    @Bindable var env: AppEnvironment
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    private var model: AppModel { env.model }

    public init(env: AppEnvironment) {
        self.env = env
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(env: env, showsNewTeam: $env.showsNewTeamSheet)
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 280)
        } detail: {
            VStack(spacing: 0) {
                if let failure = model.loadFailure {
                    BannerView(
                        banner: Banner(
                            kind: .failure,
                            title: "Your saved teams could not be opened",
                            detail: failure + "\nNothing has been written over. The file is at "
                                + model.workspaceFileURL.path)
                    ) {}
                }
                if let banner = model.banner {
                    BannerView(banner: banner) { model.banner = nil }
                }
                if let path = env.recoveredAttachmentPath {
                    RecoveredAttachmentBanner(
                        path: path,
                        copy: { env.copyRecoveredAttachmentPath() },
                        reveal: { env.revealRecoveredAttachment() },
                        dismiss: { env.dismissRecoveredAttachment() })
                }
                if let failure = model.runtimeFailure {
                    BannerView(
                        banner: Banner(kind: .warning, title: "tmux could not be read", detail: failure)
                    ) { }
                }

                switch model.mode {
                case .work:
                    WorkView(env: env)
                case .topology:
                    TopologyView(env: env)
                }
            }
            .frame(minWidth: 720, minHeight: 460)
        }
        .navigationTitle(model.selectedTopology?.name ?? "Marmy Desktop")
        .toolbar { toolbar }
        .sheet(isPresented: $env.showsNewTeamSheet) { NewTeamSheet(env: env) }
        .sheet(isPresented: $env.showsTemplates) { TemplatesView(env: env) }
        .sheet(isPresented: $env.showsSaveTemplateSheet) { SaveTemplateSheet(env: env) }
        .sheet(isPresented: $env.showsAttachSheet) { AttachSessionSheet(env: env) }
        .sheet(isPresented: $env.showsShortcuts) { ShortcutsView() }
        .sheet(item: Binding(
            get: { env.messagesForNode.map(IdentifiedNode.init) },
            set: { env.messagesForNode = $0?.id })
        ) { node in
            MessagesSheet(
                env: env, nodeID: node.id,
                title: model.selectedTopology?.node(node.id)?.displayName ?? "this agent")
        }
        .confirmationDialog(
            env.teamPendingDeletion.map { "Delete “\($0.name)”?" } ?? "Delete this team?",
            isPresented: Binding(
                get: { env.teamPendingDeletion != nil },
                set: { if !$0 { env.teamPendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            // The team is captured here, while the dialog is on screen. By the
            // time the action's task runs, the presentation binding is already
            // cleared.
            let pending = env.teamPendingDeletion
            // Cancel is the default: this is not a button to press by accident.
            Button("Cancel", role: .cancel) { env.cancelDeletion() }
            Button("Delete team", role: .destructive) {
                if let pending {
                    Task { await env.confirmDeletion(of: pending.id) }
                }
            }
        } message: {
            Text(deletionMessage)
        }
        .task { await model.refresh() }
    }

    private var deletionMessage: String {
        guard let topology = env.teamPendingDeletion else { return "" }
        let running = topology.nodes.filter { model.state(of: $0.id).isRunning }
        let base = "This removes the team and its layout from Marmy. Nothing is stopped: "
        if running.isEmpty {
            return base + "no agent in it is running right now."
        }
        let names = running.map(\.tmuxAddress).sorted().joined(separator: ", ")
        return base + "the tmux session\(running.count == 1 ? "" : "s") \(names) keep"
            + "\(running.count == 1 ? "s" : "") running and will be listed under Local sessions."
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            MarmyMark()
        }

        ToolbarItem(placement: .navigation) {
            if let topology = model.selectedTopology {
                Menu {
                    ForEach(model.topologies) { candidate in
                        Button(candidate.name) { env.selectTopology(candidate.id) }
                    }
                    Divider()
                    Button("New team…") { env.showsNewTeamSheet = true }
                    Button("Delete team…", role: .destructive) {
                        env.requestDeletion(of: topology)
                    }
                } label: {
                    Label(topology.name, systemImage: "person.2")
                }
            }
        }

        ToolbarItem(placement: .principal) {
            Picker("", selection: Binding(
                get: { model.mode },
                set: { newMode in
                    model.mode = newMode
                    env.stopCapture(reason: nil)
                })
            ) {
                ForEach(WorkMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            // Named, not guessed at: a bare triangle in a toolbar tells nobody
            // that it starts a team of agents.
            Button {
                env.showsTemplates = true
            } label: {
                Label("Templates", systemImage: "text.badge.plus")
            }
            .labelStyle(.titleAndIcon)
            .help("Role prompts and saved team shapes")

            Button {
                Task { await model.launchSelectedTeam() }
            } label: {
                if model.isLaunching {
                    Label {
                        Text("Starting…")
                    } icon: {
                        ProgressView().controlSize(.small)
                    }
                } else {
                    Label("Start team", systemImage: "play.fill")
                }
            }
            .labelStyle(.titleAndIcon)
            .disabled(model.selectedTopology == nil || model.isLaunching)
            .help("Starts every agent in this team that is not already running")

            Button {
                env.showsShortcuts = true
            } label: {
                Label("Keyboard", systemImage: "keyboard")
            }
            .help("Keyboard shortcuts")
        }
    }
}
