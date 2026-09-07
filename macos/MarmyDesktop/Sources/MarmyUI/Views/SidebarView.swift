import MarmyCore
import MarmyRuntime
import SwiftUI

/// Saved teams, and the local tmux sessions that are not part of one.
///
/// Existing sessions are only listed. Nothing is imported, renamed, restarted,
/// or spoken to until the user asks for it.
struct SidebarView: View {
    @Bindable var env: AppEnvironment
    @Binding var showsNewTeam: Bool

    private var model: AppModel { env.model }

    var body: some View {
        List {
            Section("Teams") {
                if model.topologies.isEmpty {
                    Text("No teams yet")
                        .foregroundStyle(Theme.muted)
                        .font(.callout)
                }
                ForEach(model.topologies) { topology in
                    teamRow(topology)
                    if model.isExpanded(topology.id) {
                        ForEach(Self.flatten(topology), id: \.node.id) { entry in
                            nodeRow(entry.node, depth: entry.depth)
                        }
                    }
                }
            }

            Section("Local sessions") {
                if model.unassignedSessions.isEmpty {
                    Text(model.runtimeFailure == nil ? "None running" : "tmux unavailable")
                        .foregroundStyle(Theme.muted)
                        .font(.callout)
                }
                ForEach(model.unassignedSessions, id: \.id) { session in
                    localSessionRow(session)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Theme.paper)
        .safeAreaInset(edge: .bottom) {
            Button {
                showsNewTeam = true
            } label: {
                Label("New team", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.bar)
        }
    }

    /// Reporting tree, depth-first, so the sidebar shows who reports to whom.
    static func flatten(_ topology: Topology) -> [(node: AgentNode, depth: Int)] {
        var result: [(AgentNode, Int)] = []
        var seen: Set<UUID> = []

        func visit(_ node: AgentNode, _ depth: Int) {
            guard seen.insert(node.id).inserted else { return }
            result.append((node, depth))
            for child in topology.children(of: node.id) {
                visit(child, depth + 1)
            }
        }
        for root in topology.roots { visit(root, 0) }
        // Anything left over (a corrupt parent link) is still reachable.
        for node in topology.nodes where !seen.contains(node.id) { visit(node, 0) }
        return result
    }

    /// A team's header: the whole row, the way a file explorer behaves.
    ///
    /// One button over the chevron, the name, the count and the empty space
    /// beside them, so a click anywhere along it opens or closes the team
    /// exactly once. The chevron is drawn, not pressed — a button inside a
    /// button would toggle twice.
    private func teamRow(_ topology: Topology) -> some View {
        let running = topology.nodes.filter { model.state(of: $0.id).isRunning }.count
        let isSelected = model.selectedTopologyID == topology.id && model.selectedLocalSession == nil
        let isExpanded = model.isExpanded(topology.id)

        return Button {
            // Selecting a team that is already selected would put its terminal
            // through a reconnect for nothing.
            if !isSelected { env.selectTopology(topology.id) }
            model.toggleExpansion(topology.id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(Theme.muted)
                    .frame(width: 12)
                Text(topology.name)
                    .fontWeight(isSelected ? .medium : .regular)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if running > 0 {
                    Text("\(running)/\(topology.nodes.count)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                }
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Collapse \(topology.name)" : "Expand \(topology.name)")
        .help(running > 0
            ? "\(running) of \(topology.nodes.count) agents running"
            : "No agents running in this team")
        .contextMenu {
            Button("Open in Topology view") {
                env.selectTopology(topology.id)
                model.mode = .topology
            }
            Divider()
            Button("Delete team…", role: .destructive) {
                env.requestDeletion(of: topology)
            }
        }
    }

    private func nodeRow(_ node: AgentNode, depth: Int) -> some View {
        let isSelected = model.selectedTarget == .node(node.id)
        let running = model.state(of: node.id).isRunning

        return HStack(spacing: 7) {
            KindDot(kind: node.kind)
            Text(node.displayName)
                .lineLimit(1)
            Spacer(minLength: 4)
            if running {
                Circle()
                    .fill(Theme.worker)
                    .frame(width: 6, height: 6)
                    .help("Running in \(node.tmuxAddress)")
            }
        }
        .padding(.leading, CGFloat(depth) * 12 + 6)
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { env.select(node: node.id) }
        .contextMenu { NodeMenu(env: env, nodeID: node.id) }
        .help("\(node.kind.displayName) · \(node.tmuxAddress)")
    }

    private func localSessionRow(_ session: TmuxSession) -> some View {
        let isSelected = model.selectedLocalSession?.sessionID == session.id
        // The server this row was drawn from travels with it: by the time it is
        // clicked, a refresh may have found another one.
        let server = model.readout.server

        return HStack(spacing: 7) {
            Image(systemName: "terminal")
                .font(.caption)
                .foregroundStyle(Theme.muted)
            Text(session.name).lineLimit(1)
            Spacer(minLength: 4)
            if session.isAttached {
                Image(systemName: "display")
                    .font(.caption2)
                    .foregroundStyle(Theme.muted)
                    .help("Also attached in another terminal")
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { env.select(localSession: session) }
        .contextMenu {
            Button("Open") { env.select(localSession: session) }
            Divider()
            if let server {
                Button("Stop session…", role: .destructive) {
                    env.requestTermination(of: session, on: server)
                }
            }
        }
        .help("Opens a terminal on this session. It is not added to a team and gets no instructions.")
    }
}
