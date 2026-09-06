import MarmyCore
import SwiftUI

/// Phase 1 scaffold.
///
/// It loads the persisted workspace (or the starter one on first run), reports a
/// load failure instead of quietly replacing the file, and lists what is saved.
/// Editing, the graph, the embedded terminal, and launching arrive in later
/// phases; nothing here writes to disk on its own.
struct MarmyDesktopApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Marmy Desktop") {
            RootView(model: model)
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 1080, height: 700)
        .windowToolbarStyle(.unified)
    }
}

@MainActor
@Observable
final class AppModel {
    private(set) var workspace = Workspace()
    private(set) var loadError: String?
    let store: WorkspaceStore

    init(store: WorkspaceStore = WorkspaceStore(directoryURL: WorkspaceStore.defaultDirectory())) {
        self.store = store
        reload()
    }

    func reload() {
        do {
            workspace = try store.loadOrStarter()
            loadError = nil
        } catch {
            // The file stays exactly as it is until the user decides what to do.
            workspace = Workspace()
            loadError = "\(error)"
        }
    }
}

private struct RootView: View {
    @Bindable var model: AppModel
    @State private var selection: UUID?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Teams") {
                    if model.workspace.topologies.isEmpty {
                        Text("No teams yet")
                            .foregroundStyle(Theme.muted)
                    }
                    ForEach(model.workspace.topologies) { topology in
                        Label(topology.name, systemImage: "person.2")
                            .tag(topology.id)
                    }
                }
                Section("Starter shapes") {
                    ForEach(model.workspace.topologyTemplates) { template in
                        Label(template.name, systemImage: "square.on.square.dashed")
                            .tag(template.id)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            DetailView(model: model, selection: selection)
        }
    }
}

private struct DetailView: View {
    let model: AppModel
    let selection: UUID?

    var body: some View {
        ZStack {
            Theme.paper.ignoresSafeArea()
            if let error = model.loadError {
                ContentUnavailableView {
                    Label("Workspace not loaded", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { model.reload() }
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([model.store.fileURL])
                    }
                }
            } else if let topology = selection.flatMap({ model.workspace.topology($0) }) {
                TopologySummary(topology: topology)
            } else if let template = selection.flatMap({ model.workspace.topologyTemplate($0) }) {
                TopologySummary(topology: template.prototype)
            } else {
                ContentUnavailableView(
                    "Select a team",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Editing, launching, and the embedded terminal land in the next phases."))
            }
        }
    }
}

private struct TopologySummary: View {
    let topology: Topology

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(topology.name)
                .font(.system(.title2, weight: .semibold))
                .foregroundStyle(Theme.ink)
            ForEach(topology.nodes) { node in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Circle()
                        .fill(node.kind == .manager ? Theme.manager : Theme.worker)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.displayName).foregroundStyle(Theme.ink)
                        Text("\(node.tmuxAddress) · \(node.cli.displayName) · \(node.effectiveModelDescription)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Theme.muted)
                    }
                }
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
