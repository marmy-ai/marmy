import MarmyCore
import SwiftUI

/// Role prompts and saved team shapes.
///
/// Editing a role prompt changes what future launches say. It never reaches an
/// agent that is already running.
struct TemplatesView: View {
    @Bindable var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPromptID: UUID?
    @State private var tab = Tab.roles

    enum Tab: String, CaseIterable {
        case roles = "Role prompts"
        case teams = "Team shapes"
    }

    private var model: AppModel { env.model }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
            Divider()

            switch tab {
            case .roles: rolePrompts
            case .teams: teamShapes
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .background(Theme.paper)
        .onAppear {
            env.isModalPresented = true
            selectedPromptID = selectedPromptID ?? model.workspace.promptTemplates.first?.id
        }
        .onDisappear { env.isModalPresented = false }
    }

    // MARK: - Role prompts

    private var rolePrompts: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selectedPromptID) {
                    ForEach(model.workspace.promptTemplates) { template in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(template.name).lineLimit(1)
                            Text(template.isBuiltIn ? "Shipped with Marmy" : template.summary)
                                .font(.caption)
                                .foregroundStyle(Theme.muted)
                                .lineLimit(1)
                        }
                        .tag(template.id)
                    }
                }
                Divider()
                HStack(spacing: 8) {
                    Button {
                        let template = PromptTemplate(
                            name: "New role", summary: "", applicability: .any,
                            body: "You are {{agent.name}} in tmux session {{agent.session}}.\n")
                        model.upsert(promptTemplate: template)
                        selectedPromptID = template.id
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("New role prompt")

                    Button {
                        guard let id = selectedPromptID,
                              let template = model.workspace.promptTemplate(id) else { return }
                        let copy = template.duplicated()
                        model.upsert(promptTemplate: copy)
                        selectedPromptID = copy.id
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .help("Duplicate")
                    .disabled(selectedPromptID == nil)

                    Button {
                        guard let id = selectedPromptID else { return }
                        model.deletePromptTemplate(id)
                        selectedPromptID = model.workspace.promptTemplates.first?.id
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Delete. Agents using it keep working; they simply have no role prompt.")
                    .disabled(selectedPromptID == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(width: 230)

            Divider()

            if let id = selectedPromptID, let template = model.workspace.promptTemplate(id) {
                PromptTemplateEditor(env: env, template: template)
            } else {
                EmptyStateView(
                    title: "No role prompt selected",
                    message: "Pick one on the left, or create a new one.",
                    symbol: "text.alignleft"
                ) { EmptyView() }
            }
        }
    }

    // MARK: - Team shapes

    private var teamShapes: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(model.workspace.topologyTemplates) { template in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(template.name).font(.callout.weight(.medium))
                            Text(template.summary.isEmpty
                                ? shapeSummary(template.prototype)
                                : template.summary)
                                .font(.caption)
                                .foregroundStyle(Theme.muted)
                            Text(template.prototype.nodes.map { "\($0.displayName) (\($0.kind.displayName))" }
                                .joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        Button("Create team") {
                            _ = model.instantiate(
                                templateID: template.id,
                                named: template.name,
                                directory: nil)
                            dismiss()
                        }
                        if let topology = model.selectedTopology {
                            Button("Update from “\(topology.name)”") {
                                var updated = TopologyTemplate(capturing: topology, name: template.name)
                                updated.id = template.id
                                updated.summary = template.summary
                                model.upsert(topologyTemplate: updated)
                            }
                            .help("Replaces this shape with the current team's structure.")
                        }
                        if !template.isBuiltIn {
                            Button(role: .destructive) {
                                model.deleteTopologyTemplate(template.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .padding(12)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1))
                }

                if let topology = model.selectedTopology {
                    Button("Save “\(topology.name)” as a new shape") {
                        model.saveSelectedTeamAsTemplate(named: topology.name)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(16)
        }
    }

    private func shapeSummary(_ topology: Topology) -> String {
        let managers = topology.nodes.filter { $0.kind == .manager }.count
        let workers = topology.nodes.count - managers
        return "\(managers) manager\(managers == 1 ? "" : "s"), \(workers) worker\(workers == 1 ? "" : "s")"
    }
}

/// Edits one role prompt, with the variables it can use and a live preview.
struct PromptTemplateEditor: View {
    @Bindable var env: AppEnvironment
    let template: PromptTemplate

    private var model: AppModel { env.model }

    private var issues: [ValidationIssue] {
        TopologyValidator.validate(template: current)
    }

    private var current: PromptTemplate {
        model.workspace.promptTemplate(template.id) ?? template
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                TextField("Name", text: field(\.name))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                Picker("", selection: field(\.applicability)) {
                    ForEach(PromptTemplate.Applicability.allCases, id: \.self) { value in
                        Text(label(for: value)).tag(value)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
                Spacer()
                if current.isBuiltIn {
                    Button("Reset to shipped text") { resetToShipped() }
                        .help("Restores the wording Marmy ships with.")
                }
            }
            .padding(12)

            Divider()

            HSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    TextEditor(text: field(\.body))
                        .font(.system(.callout, design: .monospaced))
                        .padding(6)
                    Divider()
                    issueBar
                }
                .frame(minWidth: 330)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Variables")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(PromptVariables.allKeys, id: \.self) { key in
                                Button {
                                    insert("{{\(key)}}")
                                } label: {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text("{{\(key)}}")
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(Theme.ink)
                                        Text(PromptVariables.keyDescriptions[key] ?? "")
                                            .font(.caption2)
                                            .foregroundStyle(Theme.muted)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                .help("Insert at the end of the template")
                            }
                            Text("Sections: {{#name}}…{{/name}} shows when a value exists, "
                                + "{{^name}}…{{/name}} when it does not.")
                                .font(.caption2)
                                .foregroundStyle(Theme.muted)
                                .padding(.top, 6)
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                    }
                    Divider()
                    preview
                }
                .frame(minWidth: 260)
            }
        }
    }

    @ViewBuilder
    private var issueBar: some View {
        if let issue = issues.first {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(issue.severity.tint)
                Text(issue.message)
                    .font(.caption)
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                Spacer()
            }
            .padding(8)
            .background(issue.severity.tint.opacity(0.08))
        } else {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle").foregroundStyle(Theme.worker)
                Text("This template parses. Every variable it uses is known.")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                Spacer()
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Preview")
                    .font(.callout.weight(.medium))
                if let subject = previewSubject {
                    Text("as \(subject.displayName) (\(subject.tmuxAddress))")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            ScrollView {
                Text(previewText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .frame(height: 220)
    }

    private var previewSubject: AgentNode? {
        model.previewSubject(for: current)
    }

    private var previewText: String {
        guard let node = previewSubject else {
            return "Select a team to preview this prompt with real names."
        }
        switch model.previewPrompt(template: current, for: node) {
        case .success(let text): return text
        case .failure(let error): return "\(error)"
        }
    }

    private func label(for applicability: PromptTemplate.Applicability) -> String {
        switch applicability {
        case .manager: return "Managers"
        case .worker: return "Workers"
        case .any: return "Any agent"
        }
    }

    private func insert(_ text: String) {
        var updated = current
        if !updated.body.hasSuffix("\n") { updated.body += "\n" }
        updated.body += text
        model.upsert(promptTemplate: updated)
    }

    private func resetToShipped() {
        let shipped = DefaultTemplates.promptTemplates().first { $0.id == current.id }
        guard let shipped else { return }
        model.upsert(promptTemplate: shipped)
    }

    private func field<Value>(_ keyPath: WritableKeyPath<PromptTemplate, Value>) -> Binding<Value> {
        Binding(
            get: { current[keyPath: keyPath] },
            set: { newValue in
                var updated = current
                updated[keyPath: keyPath] = newValue
                model.upsert(promptTemplate: updated)
            })
    }
}
