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
                    TextField("Name", text: Binding(
                        get: {
                            model.selectedTopology?.node(node.id)?.displayName ?? node.displayName
                        },
                        set: { model.rename(node.id, to: $0) }))
                        .textFieldStyle(.roundedBorder)
                        .help("The name you see, and the name of the tmux session a future start "
                            + "will ask for.")
                }
                connection(for: node)
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
                if node.cli.supportsModelChoice {
                    LabeledField(label: "Model") {
                        TextField("CLI default", text: binding(for: node, \.model))
                            .textFieldStyle(.roundedBorder)
                            .help("Leave empty to use whatever the CLI is configured to use.")
                    }
                } else {
                    LabeledField(label: "Model") {
                        Text("Not used — this is a shell you drive yourself")
                            .font(.callout)
                            .foregroundStyle(Theme.muted)
                    }
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
                LabeledField(label: "Reports to") {
                    Picker("", selection: Binding(
                        get: { node.parentID },
                        set: { _ = model.reparent(node.id, to: $0) })
                    ) {
                        Text("None (root)").tag(UUID?.none)
                        ForEach(parentCandidates(for: node, in: topology)) { candidate in
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
                if !node.acceptsAgentMessages {
                    Text("A terminal starts as your login shell in that folder. Marmy sends it no "
                        + "starting prompt, no role instructions, and no automatic updates — text "
                        + "typed into a shell is a command. Its role and contacts still show in the "
                        + "graph, and other agents are told it is a manual terminal.")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                rolePrompt(for: node)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Extra instructions for this agent")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                    Text("Added to the role prompt above, for this agent only.")
                        .font(.caption2)
                        .foregroundStyle(Theme.muted)
                    TextEditor(text: binding(for: node, \.notes))
                        .font(.callout)
                        .frame(height: 64)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line, lineWidth: 1))
                        .disabled(!node.acceptsAgentMessages)
                }
                Button(showsPrompt ? "Hide starting prompt" : "Preview starting prompt") {
                    showsPrompt.toggle()
                }
                .buttonStyle(.link)
                .font(.callout)
                .disabled(!node.acceptsAgentMessages)
                if showsPrompt {
                    Text("Preview — the starting prompt as it would be resolved for the next "
                        + "start. Nothing here has been sent.")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                    promptPreview(for: node)
                }
            }

            group("Messages") {
                Text("What Marmy has actually said to this agent, exactly as it was sent — "
                    + "starting prompt included.")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Show messages\(env.unsettledMessageCount(node.id) > 0 ? " (\(env.unsettledMessageCount(node.id)) waiting)" : "")") {
                    env.messagesForNode = node.id
                }
                .buttonStyle(.link)
                .font(.callout)
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

    /// Where this agent actually is, and what its name would ask for next time.
    ///
    /// A name is a plan, not a command: Marmy never renames a tmux session, so a
    /// running agent keeps the one it is in. When the two differ, that is said
    /// rather than left to be discovered at the next start.
    @ViewBuilder
    private func connection(for node: AgentNode) -> some View {
        let planned = node.sessionName
        VStack(alignment: .leading, spacing: 2) {
            switch model.state(of: node.id) {
            case .running(_, let sessionName, _):
                handle("Connected to tmux:", sessionName, tint: Theme.worker)
                if sessionName != planned {
                    handle("Next start:", planned, tint: Theme.muted)
                }
            default:
                handle("tmux name:", planned, tint: Theme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A label and a session name you can select and copy.
    private func handle(_ label: String, _ name: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(Theme.muted)
            Text(name)
                .foregroundStyle(tint)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption)
    }

    /// The role prompt, its scope, and the two ways of changing it.
    ///
    /// The distinction the buttons draw is the one that matters: editing the
    /// role prompt changes it for every agent using it, and customising it gives
    /// this one agent a copy of its own. Both are said out loud rather than left
    /// to be discovered, and neither reaches an agent that is already running —
    /// a role prompt is read when an agent is started.
    @ViewBuilder
    private func rolePrompt(for node: AgentNode) -> some View {
        let template = node.promptTemplateID.flatMap { model.workspace.promptTemplate($0) }
        let users = node.promptTemplateID.map { model.agentsUsing(promptTemplate: $0) } ?? []
        let isEditable = node.acceptsAgentMessages

        VStack(alignment: .leading, spacing: 6) {
            Text("Role prompt")
                .font(.caption)
                .foregroundStyle(Theme.muted)
            Picker("", selection: binding(for: node, \.promptTemplateID)) {
                Text("None").tag(UUID?.none)
                ForEach(model.workspace.promptTemplates.filter {
                    $0.applicability.matches(node.kind)
                }) { template in
                    Text(template.name).tag(UUID?.some(template.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .disabled(!isEditable)

            if let template {
                if !template.summary.isEmpty {
                    Text(template.summary)
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(scope(users: users))
                    .font(.caption)
                    .foregroundStyle(users.count > 1 ? Theme.warning : Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Edit role prompt…") {
                    env.templateToEdit = template.id
                    env.showsTemplates = true
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(!isEditable)
                .help("Changes this reusable role prompt for every agent using it. Applies on "
                    + "next start.")

                Button("Customize for this agent…") {
                    guard let copy = model.customizePromptTemplate(for: node.id) else { return }
                    env.templateToEdit = copy.id
                    env.showsTemplates = true
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(!isEditable)
                .help("Copies this role prompt for \(node.displayName) alone and opens the copy. "
                    + "Everyone else keeps this one.")
            } else {
                Text("No role prompt: this agent starts with no role instructions.")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Choose or create a role…") {
                    env.templateToEdit = nil
                    env.showsTemplates = true
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(!isEditable)
                .help("Opens the role prompts. Pick one above once it exists.")
            }
        }
    }

    /// Who else an edit would reach, in one line.
    private func scope(users: [AgentNode]) -> String {
        let others = users.count - 1
        switch others {
        case ..<1: return "Used by this agent only. Applies on next start."
        case 1: return "Shared with 1 other agent — Edit changes theirs too, Customize copies it "
            + "for this one. Applies on next start."
        default: return "Shared with \(others) other agents — Edit changes theirs too, Customize "
            + "copies it for this one. Applies on next start."
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

    /// Anyone this agent could report to without making a loop — manager or
    /// worker, at any depth.
    private func parentCandidates(for node: AgentNode, in topology: Topology) -> [AgentNode] {
        topology.nodes.filter { $0.id != node.id && topology.canReparent(node.id, to: $0.id) }
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
