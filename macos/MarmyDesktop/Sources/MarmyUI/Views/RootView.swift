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
        // The window is named on the window itself: a navigation title would be
        // drawn in the header, repeating the team menu next to it.
        .background(WindowTitle(
            title: model.selectedTopology.map { "Marmy — \($0.name)" } ?? "Marmy"))
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
            env.pendingTermination?.title ?? "Delete this team?",
            isPresented: Binding(
                get: { env.pendingTermination != nil },
                set: { if !$0 { env.cancelDeletion() } }),
            titleVisibility: .visible
        ) {
            // The plan is captured here, while the dialog is on screen: by the
            // time an action's task runs the binding is already cleared, and
            // what is running may have moved on.
            if let plan = env.pendingTermination {
                terminationActions(for: plan)
            }
        } message: {
            Text(env.pendingTermination?.message ?? "")
        }
        .task { await model.refresh() }
    }

    /// A team name that cannot push the toolbar's buttons off the edge.
    static func short(_ name: String?, limit: Int = 20) -> String? {
        guard let name else { return nil }
        guard name.count > limit else { return name }
        return name.prefix(limit - 1).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The choices a confirmation offers, which depend on what it is about.
    @ViewBuilder
    private func terminationActions(for plan: SessionTerminationPlan) -> some View {
        // Cancel first: this is not a dialog to dismiss by reflex.
        Button("Cancel", role: .cancel) { env.cancelDeletion() }
        switch plan.subject {
        case .team:
            Button("Delete team, keep sessions") {
                Task { await env.confirmDeletion(plan, terminating: false) }
            }
            if !plan.sessions.isEmpty {
                Button("Delete team and stop \(plan.sessions.count) session\(plan.sessions.count == 1 ? "" : "s")", role: .destructive) {
                    Task { await env.confirmDeletion(plan, terminating: true) }
                }
            }
        case .session:
            Button("Stop session", role: .destructive) {
                Task { await env.confirmTermination(plan) }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // The mark stands on its own: inside a Menu, AppKit reads the image's
        // own size and the item grows to the icon's 512 points.
        ToolbarItem(placement: .navigation) {
            MarmyMark()
        }

        // Text only, and bounded here rather than on the label: a long team
        // name must not push the buttons that do something into the overflow.
        ToolbarItem(placement: .navigation) {
            Menu {
                ForEach(model.topologies) { candidate in
                    Button(candidate.name) { env.selectTopology(candidate.id) }
                }
                Divider()
                Button("New team…") { env.showsNewTeamSheet = true }
                if let topology = model.selectedTopology {
                    Button("Delete team…", role: .destructive) {
                        env.requestDeletion(of: topology)
                    }
                }
            } label: {
                Text(Self.short(model.selectedTopology?.name) ?? "Teams")
            }
            .frame(maxWidth: 150)
            .help(model.selectedTopology.map { "Team: \($0.name)" } ?? "Teams")
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
            // Narrow enough to leave the named buttons room at the minimum
            // window width; both words still fit.
            .frame(width: 160)
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
