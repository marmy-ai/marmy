import AppKit
import MarmyCore
import SwiftUI

/// Edits the selected agent. Every field here changes what a future launch does;
/// nothing is pushed into a session that is already running.
struct InspectorView: View {
    @Bindable var env: AppEnvironment
    @State private var showsPrompt = false

    private var model: AppModel { env.model }

    private var node: AgentNode? {
        guard let topology = model.selectedTopology, let id = model.inspectedNodeID else { return nil }
        return topology.node(id)
    }

    var body: some View {
        ScrollView {
            if let node, let topology = model.selectedTopology {
                fields(for: node, in: topology)
                    .padding(16)
            } else {
                VStack(spacing: 8) {
                    Text("No agent selected")
                        .font(.callout)
                        .foregroundStyle(Theme.muted)
                    Text("Pick a node on the canvas to edit it.")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
            }
        }
        .background(Theme.surface)
    }

    @ViewBuilder
    private func fields(for node: AgentNode, in topology: Topology) -> some View {
        let isLive = model.state(of: node.id).isRunning

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                KindDot(kind: node.kind, size: 9)
                Text(node.displayName)
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                Spacer()
            }

            if isLive {
                Text("This agent is running. Name and directory changes apply the next time it is started — "
                    + "they do not move the live session.")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            group("Identity") {
                LabeledField(label: "Name") {
                    TextField("Display name", text: binding(for: node, \.displayName))
                        .textFieldStyle(.roundedBorder)
                }
                LabeledField(label: "Session") {
                    TextField("tmux session", text: binding(for: node, \.sessionName))
                        .textFieldStyle(.roundedBorder)
                        .disabled(isLive)
                        .help(isLive
                            ? "The session name is fixed while this agent is running."
                            : "Letters, digits, hyphen and underscore.")
                }
                if let problem = TmuxName.problem(with: node.sessionName) {
                    Text(problem.message)
                        .font(.caption)
                        .foregroundStyle(Theme.danger)
                }
                LabeledField(label: "Kind") {
                    Picker("", selection: Binding(
                        get: { model.selectedTopology?.node(node.id)?.kind ?? node.kind },
                        set: { model.changeKind(of: node.id, to: $0) })
                    ) {
                        ForEach(AgentKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .labelsHidden()
                }
                LabeledField(label: "Role") {
                    TextField("What they do", text: binding(for: node, \.roleTitle))
                        .textFieldStyle(.roundedBorder)
                }
            }

            group("Program") {
                LabeledField(label: "CLI") {
                    Picker("", selection: binding(for: node, \.cli)) {
                        ForEach(AgentCLI.allCases, id: \.self) { cli in
                            Text(cli.displayName).tag(cli)
                        }
                    }
                    .labelsHidden()
                }
                LabeledField(label: "Model") {
                    TextField("CLI default", text: binding(for: node, \.model))
                        .textFieldStyle(.roundedBorder)
                        .help("Leave empty to use whatever the CLI is configured to use.")
                }
                LabeledField(label: "Folder") {
                    HStack(spacing: 6) {
                        TextField("Working directory", text: binding(for: node, \.workingDirectory))
                            .textFieldStyle(.roundedBorder)
                        Button("Choose…") { chooseDirectory(for: node) }
                            .controlSize(.small)
                    }
                }
            }

            group("Reporting") {
                LabeledField(label: "Manager") {
                    Picker("", selection: Binding(
                        get: { node.parentID },
                        set: { _ = model.reparent(node.id, to: $0) })
                    ) {
                        Text("None (root)").tag(UUID?.none)
                        ForEach(managerCandidates(for: node, in: topology)) { candidate in
                            Text(candidate.displayName).tag(UUID?.some(candidate.id))
                        }
                    }
                    .labelsHidden()
                }
                if !topology.children(of: node.id).isEmpty {
                    Text("Reports: " + topology.children(of: node.id).map(\.displayName).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }
            }

            group("May also talk to") {
                ForEach(otherNodes(node, in: topology)) { other in
                    Toggle(isOn: Binding(
                        get: { node.contactIDs.contains(other.id) },
                        set: { on in toggleContact(node, other, on: on) })
                    ) {
                        HStack(spacing: 6) {
                            KindDot(kind: other.kind, size: 7)
                            Text(other.displayName).font(.callout)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                if otherNodes(node, in: topology).isEmpty {
                    Text("No one else in this team yet.")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }
            }

            group("Instructions") {
                LabeledField(label: "Role prompt") {
                    Picker("", selection: binding(for: node, \.promptTemplateID)) {
                        Text("None").tag(UUID?.none)
                        ForEach(model.workspace.promptTemplates.filter { $0.applicability.matches(node.kind) }) { template in
                            Text(template.name).tag(UUID?.some(template.id))
                        }
                    }
                    .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Extra instructions for this agent")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                    TextEditor(text: binding(for: node, \.notes))
                        .font(.callout)
                        .frame(height: 64)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line, lineWidth: 1))
                }
                Button(showsPrompt ? "Hide starting prompt" : "Show starting prompt") {
                    showsPrompt.toggle()
                }
                .buttonStyle(.link)
                .font(.callout)
                if showsPrompt {
                    promptPreview(for: node)
                }
            }

            Divider()
            Button(role: .destructive) {
                Task { await model.deleteNode(node.id) }
            } label: {
                Label("Remove from team", systemImage: "trash")
            }
            .help("Removes the agent from this team. A running session keeps running and moves to Local sessions.")
        }
    }

    @ViewBuilder
    private func promptPreview(for node: AgentNode) -> some View {
        switch model.renderedPrompt(for: node) {
        case .success(let text):
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 180)
            .background(Theme.paper)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line, lineWidth: 1))
        case .failure(let error):
            Text("\(error)")
                .font(.caption)
                .foregroundStyle(Theme.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(Theme.ink)
            content()
        }
    }

    private func managerCandidates(for node: AgentNode, in topology: Topology) -> [AgentNode] {
        topology.nodes.filter { $0.kind == .manager && $0.id != node.id && topology.canReparent(node.id, to: $0.id) }
    }

    private func otherNodes(_ node: AgentNode, in topology: Topology) -> [AgentNode] {
        topology.nodes.filter { $0.id != node.id }
    }

    private func toggleContact(_ node: AgentNode, _ other: AgentNode, on: Bool) {
        guard var topology = model.selectedTopology else { return }
        if on {
            topology.linkContacts(node.id, other.id)
        } else {
            topology.unlinkContacts(node.id, other.id)
        }
        model.update(topology)
    }

    private func chooseDirectory(for node: AgentNode) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: NSString(string: node.workingDirectory).expandingTildeInPath)
        env.isModalPresented = true
        defer { env.isModalPresented = false }
        if panel.runModal() == .OK, let url = panel.url {
            binding(for: node, \.workingDirectory).wrappedValue = url.path
        }
    }

    /// Writes a single field back into the workspace and saves.
    private func binding<Value>(
        for node: AgentNode,
        _ keyPath: WritableKeyPath<AgentNode, Value>
    ) -> Binding<Value> {
        Binding(
            get: {
                model.selectedTopology?.node(node.id)?[keyPath: keyPath] ?? node[keyPath: keyPath]
            },
            set: { newValue in
                guard var topology = model.selectedTopology, var updated = topology.node(node.id) else { return }
                updated[keyPath: keyPath] = newValue
                topology.upsert(updated)
                model.update(topology)
            })
    }
}
