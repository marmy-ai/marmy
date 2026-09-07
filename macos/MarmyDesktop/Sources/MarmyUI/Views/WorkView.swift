import MarmyCore
import MarmyRuntime
import SwiftUI

/// The daily view: who is selected, their terminal, and what you want to say.
struct WorkView: View {
    @Bindable var env: AppEnvironment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var model: AppModel { env.model }

    var body: some View {
        VStack(spacing: 0) {
            if let target = model.selectedTarget {
                header(for: target)
                Divider()
                if case .node(let nodeID) = target, let topology = model.selectedTopology {
                    PeerStrip(env: env, topology: topology, selected: nodeID)
                    Divider()
                }
                terminalArea(for: target)
                Divider()
                ComposerView(env: env, target: target)
            } else {
                emptyState
            }
        }
        .background(Theme.paper)
        .task(id: model.selectedTarget) {
            env.syncTerminal()
            env.focusTerminal()
        }
        .task(id: terminalIdentityKey) {
            env.syncTerminal()
        }
    }

    private var terminalIdentityKey: String {
        model.selectedTarget.flatMap { env.terminalIdentity(for: $0)?.key } ?? ""
    }

    // MARK: - Header

    @ViewBuilder
    private func header(for target: WorkTarget) -> some View {
        let connection = model.connection(for: target)
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if let node = model.selectedNode, target == .node(node.id) {
                        KindDot(kind: node.kind, size: 9)
                        Text(node.displayName)
                            .font(.system(.title2, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                        if !node.roleTitle.isEmpty {
                            Text(node.roleTitle)
                                .font(.callout)
                                .foregroundStyle(Theme.muted)
                        }
                        if !node.acceptsAgentMessages {
                            Text("manual terminal")
                                .font(.caption)
                                .foregroundStyle(Theme.muted)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 4).fill(Theme.line.opacity(0.5)))
                                .help("A shell you drive yourself. Marmy sends it nothing.")
                        }
                    } else if case .localSession(let key) = target {
                        Image(systemName: "terminal").foregroundStyle(Theme.muted)
                        Text(model.readout.sessions.first { $0.id == key.sessionID }?.name ?? "Session")
                            .font(.system(.title2, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                        Text("local session")
                            .font(.callout)
                            .foregroundStyle(Theme.muted)
                    }
                }
                subtitle(for: target)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 8) {
                StatusPill(connection: connection)
                actions(for: target, connection: connection)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func subtitle(for target: WorkTarget) -> some View {
        switch target {
        case .node:
            if let node = model.selectedNode {
                HStack(spacing: 10) {
                    Text(node.cli.displayName)
                    Text("·")
                    Text(node.effectiveModelDescription)
                    Text("·")
                    Text(node.workingDirectory)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(node.workingDirectory)
                }
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(Theme.muted)
            }
        case .localSession(let key):
            HStack(spacing: 10) {
                Text(key.sessionID)
                if let pane = model.readout.panes.first(where: { $0.sessionID == key.sessionID && $0.isActive }) {
                    Text("·")
                    Text(pane.currentPath).lineLimit(1).truncationMode(.head)
                }
            }
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(Theme.muted)
        }
    }

    @ViewBuilder
    private func actions(for target: WorkTarget, connection: TargetConnection) -> some View {
        HStack(spacing: 8) {
            if case .node(let nodeID) = target {
                if connection.isLive {
                    Button("Reconnect terminal") { env.reconnectTerminal() }
                        .help("Attaches a new terminal client. The agent keeps running.")
                } else {
                    Button(model.isLaunching ? "Starting…" : "Start agent") {
                        Task { await model.startNode(nodeID) }
                    }
                    .disabled(model.isLaunching)
                    .keyboardShortcut("r", modifiers: [.command])
                }
            } else if connection.isLive {
                Button("Reconnect terminal") { env.reconnectTerminal() }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    // MARK: - Terminal

    @ViewBuilder
    private func terminalArea(for target: WorkTarget) -> some View {
        ZStack(alignment: .topTrailing) {
            terminalContent(for: target)
            if env.history.isShowingHistory {
                // The live terminal keeps running underneath, untouched.
                TerminalHistoryOverlay(env: env)
                    .transition(.opacity)
            }
            if env.showsLocationHint, case .node(let nodeID) = target, let topology = model.selectedTopology {
                LocationHintView(topology: topology, selected: nodeID)
                    .padding(14)
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: env.showsLocationHint)
    }

    @ViewBuilder
    private func terminalContent(for target: WorkTarget) -> some View {
        if let pane = env.currentPane {
            ZStack(alignment: .bottom) {
                TerminalHostView(terminal: pane.view, focusOnAppear: true)
                    .background(Theme.terminalBackground)
                if case .detached(let reason) = pane.connection {
                    disconnected(reason: reason)
                }
            }
        } else {
            switch model.connection(for: target) {
            case .notStarted:
                notStartedState(for: target)
            case .starting:
                ProgressView("Starting…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ended(let reason), .failed(let reason):
                EmptyStateView(
                    title: "No terminal here yet",
                    message: reason,
                    symbol: "bolt.horizontal.circle"
                ) {
                    if case .node(let nodeID) = target {
                        Button("Start agent") { Task { await model.startNode(nodeID) } }
                            .buttonStyle(.borderedProminent)
                    }
                }
            case .attached:
                ProgressView("Attaching…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func disconnected(reason: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "bolt.horizontal.circle").foregroundStyle(Theme.warning)
            Text(reason)
                .font(.callout)
                .foregroundStyle(Theme.ink)
            Spacer()
            Button("Reconnect") { env.reconnectTerminal() }
                .controlSize(.small)
        }
        .padding(12)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private func notStartedState(for target: WorkTarget) -> some View {
        let issues = startupIssues(for: target)
        EmptyStateView(
            title: "Not started yet",
            message: issues.isEmpty
                ? "Start this agent to open its terminal. Marmy creates a tmux session and launches its CLI."
                : issues.joined(separator: "\n"),
            symbol: "play.circle"
        ) {
            if case .node(let nodeID) = target {
                Button("Start agent") { Task { await model.startNode(nodeID) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isLaunching)
                Button("Attach an existing session…") { env.showsAttachSheet = true }
            }
        }
    }

    private func startupIssues(for target: WorkTarget) -> [String] {
        guard case .node(let nodeID) = target, let report = model.lastPreflight else { return [] }
        return report.errors.filter { $0.nodeID == nodeID }.map(\.message)
    }

    private var emptyState: some View {
        EmptyStateView(
            title: model.topologies.isEmpty ? "No teams yet" : "Nothing selected",
            message: model.topologies.isEmpty
                ? "Create a team to start agents in tmux, or open one of your existing sessions from the sidebar."
                : "Pick an agent in the sidebar, or open a local session."
        ) {
            Button("New team") { env.showsNewTeamSheet = true }
                .buttonStyle(.borderedProminent)
        }
    }
}

/// The agents at the selected one's level, so moving sideways is visible.
///
/// At the top level those are the top-level agents of every team, labelled with
/// the team they belong to; under a manager they are that manager's reports.
/// One row, always: with a dozen peers it scrolls sideways rather than squeezing
/// names into columns of letters and eating the terminal's height.
struct PeerStrip: View {
    @Bindable var env: AppEnvironment
    let topology: Topology
    let selected: UUID

    private var model: AppModel { env.model }

    var body: some View {
        let peers = model.peerLocations(of: selected)
        let parent = topology.node(selected)?.parentID.flatMap { topology.node($0) }
        let reports = topology.children(of: selected)
        let isRootLayer = topology.node(selected)?.parentID == nil

        HStack(spacing: 8) {
            if let parent {
                Button {
                    env.select(node: parent.id)
                    env.showLocationHint()
                } label: {
                    Label(parent.displayName, systemImage: "arrow.up")
                        .font(.callout)
                        .lineLimit(1)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.muted)
                .fixedSize()
                .help("Manager — Command-Up")
                Divider().frame(height: 16)
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(peers, id: \.self) { peer in
                            peerChip(peer, showsTeam: isRootLayer && peer.topologyID != topology.id)
                                .id(peer.nodeID)
                        }
                    }
                    .padding(.vertical, 1)
                }
                // `initial: true` so returning from the graph also shows the
                // agent named in the header, not the start of the row.
                .onChange(of: selected, initial: true) { _, newValue in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !reports.isEmpty {
                Divider().frame(height: 16)
                Button {
                    env.navigate(.child)
                } label: {
                    Label("\(reports.count) report\(reports.count == 1 ? "" : "s")", systemImage: "arrow.down")
                        .font(.callout)
                        .lineLimit(1)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.muted)
                .fixedSize()
                .help("Reports — Command-Down")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .frame(height: 40)
    }

    private func peerChip(_ location: AgentLocation, showsTeam: Bool) -> some View {
        let peer = model.node(at: location)
        let teamName = model.teamName(of: location)

        return Button {
            env.select(node: location.nodeID)
            env.showLocationHint()
        } label: {
            HStack(spacing: 6) {
                if let peer { KindDot(kind: peer.kind, size: 7) }
                if showsTeam {
                    // Root-layer peers come from every team, so say which.
                    Text(teamName)
                        .font(.callout)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                    Text("·")
                        .font(.callout)
                        .foregroundStyle(Theme.muted)
                }
                Text(peer?.displayName ?? "Unknown")
                    .font(.callout)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(location.nodeID == selected ? (peer?.kind.tint ?? Theme.line).opacity(0.14) : Color.clear))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        location.nodeID == selected ? (peer?.kind.tint ?? Theme.line).opacity(0.5) : Theme.line,
                        lineWidth: 1))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.ink)
        .fixedSize()
        .help("\(teamName) · \(peer?.kind.displayName ?? "") \(peer?.displayName ?? "")")
    }
}

/// The small "where am I" graphic that appears while navigating, then fades.
struct LocationHintView: View {
    let topology: Topology
    let selected: UUID

    var body: some View {
        let peers = TopologyNavigator.peers(of: selected, in: topology)
        let parent = topology.node(selected)?.parentID.flatMap { topology.node($0) }

        VStack(alignment: .leading, spacing: 6) {
            if let parent {
                Text(parent.displayName)
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
            HStack(spacing: 5) {
                ForEach(peers) { peer in
                    Circle()
                        .fill(peer.id == selected ? peer.kind.tint : Theme.line)
                        .frame(width: peer.id == selected ? 9 : 7, height: peer.id == selected ? 9 : 7)
                }
            }
            Text(topology.node(selected)?.displayName ?? "")
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.ink)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1))
        .accessibilityHidden(true)
    }
}
