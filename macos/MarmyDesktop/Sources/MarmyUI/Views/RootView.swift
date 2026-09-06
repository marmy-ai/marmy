import MarmyCore
import SwiftUI

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
        .task { await model.refresh() }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if let topology = model.selectedTopology {
                Menu {
                    ForEach(model.topologies) { candidate in
                        Button(candidate.name) { env.selectTopology(candidate.id) }
                    }
                    Divider()
                    Button("New team…") { env.showsNewTeamSheet = true }
                    Button("Remove this team…", role: .destructive) {
                        Task { await model.deleteSelectedTopology() }
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
            Button {
                env.showsTemplates = true
            } label: {
                Label("Templates", systemImage: "text.badge.plus")
            }
            .help("Role prompts and saved team shapes")

            Button {
                Task { await model.launchSelectedTeam() }
            } label: {
                if model.isLaunching {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Launch team", systemImage: "play.fill")
                }
            }
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
