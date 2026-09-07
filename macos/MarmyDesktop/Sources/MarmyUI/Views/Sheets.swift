import AppKit
import MarmyCore
import MarmyRuntime
import SwiftUI

/// Creates a team from a starter shape, in a folder the user picks.
struct NewTeamSheet: View {
    @Bindable var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var name = "New team"
    @State private var directory = FileManager.default.homeDirectoryForCurrentUser.path
    @State private var shape: Shape = .leadAndTwoWorkers
    @State private var managerProgram: Program = .cli(.claude)
    @State private var workerProgram: Program = .cli(.claude)

    /// What each half of the team runs. Teams are often mixed — one CLI to plan
    /// and review, another to write the code — so the manager and the workers
    /// are chosen separately, and a shape that already says what each agent
    /// runs can simply be left alone.
    enum Program: Hashable, Identifiable {
        case fromShape
        case cli(AgentCLI)

        var id: String {
            switch self {
            case .fromShape: return "shape"
            case .cli(let cli): return cli.rawValue
            }
        }

        var title: String {
            switch self {
            case .fromShape: return "As the shape says"
            case .cli(let cli): return cli.displayName
            }
        }
    }

    enum Shape: String, CaseIterable, Identifiable {
        case leadAndWorker
        case leadAndTwoWorkers
        case singleManager

        var id: String { rawValue }

        var title: String {
            switch self {
            case .leadAndWorker: return "Lead and one worker"
            case .leadAndTwoWorkers: return "Lead and two workers"
            case .singleManager: return "One manager to start"
            }
        }

        var detail: String {
            switch self {
            case .leadAndWorker:
                return "A manager who reviews and commits, and one agent who writes the code."
            case .leadAndTwoWorkers:
                return "A manager with an implementer and a verifier who may talk to each other."
            case .singleManager:
                return "Creates a single manager in that folder. Add the rest on the topology canvas."
            }
        }

        var templateID: UUID? {
            switch self {
            case .leadAndWorker: return DefaultTemplates.ID.pairTeam
            case .leadAndTwoWorkers: return DefaultTemplates.ID.starterTeam
            case .singleManager: return nil
            }
        }
    }

    private var model: AppModel { env.model }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New team")
                .font(.title3.weight(.semibold))

            LabeledField(label: "Name") {
                TextField("Team name", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledField(label: "Folder") {
                HStack(spacing: 8) {
                    Text(directory)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Choose…") { chooseDirectory() }
                }
            }

            LabeledField(label: "Manager runs") {
                programPicker(selection: $managerProgram)
            }
            if shape != .singleManager {
                LabeledField(label: "Workers run") {
                    programPicker(selection: $workerProgram)
                }
                Text("A mixed team is fine: the manager and its workers do not have to run the "
                    + "same program. Terminal starts a plain shell — Marmy sends it nothing, so a "
                    + "team of terminals has nobody to delegate to.")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Shape").font(.callout).foregroundStyle(Theme.muted)
                ForEach(Shape.allCases) { option in
                    Button {
                        shape = option
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: shape == option ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(shape == option ? Color.accentColor : Theme.muted)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title).foregroundStyle(Theme.ink)
                                Text(option.detail)
                                    .font(.caption)
                                    .foregroundStyle(Theme.muted)
                            }
                            Spacer()
                        }
                        .padding(9)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(shape == option ? Color.accentColor.opacity(0.08) : .clear))
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("Models stay at whatever each CLI is configured to use unless you set one per agent.")
                .font(.caption)
                .foregroundStyle(Theme.muted)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create team") { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { env.isModalPresented = true }
        .onDisappear { env.isModalPresented = false }
    }

    @ViewBuilder
    private func programPicker(selection: Binding<Program>) -> some View {
        Picker("", selection: selection) {
            if shape.templateID != nil {
                Text(Program.fromShape.title).tag(Program.fromShape)
            }
            ForEach(AgentCLI.allCases, id: \.self) { cli in
                Text(cli.displayName).tag(Program.cli(cli))
            }
        }
        .labelsHidden()
        .frame(width: 200)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: directory)
        if panel.runModal() == .OK, let url = panel.url {
            directory = url.path
        }
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let templateID = shape.templateID {
            if var topology = model.instantiate(templateID: templateID, named: trimmed, directory: directory) {
                for index in topology.nodes.indices {
                    let choice = topology.nodes[index].kind == .manager ? managerProgram : workerProgram
                    if case .cli(let cli) = choice {
                        topology.nodes[index].cli = cli
                    }
                }
                model.update(topology)
                env.selectTopology(topology.id)
            }
        } else {
            var allocator = SessionNameAllocator(existingNames: model.allClaimedSessionNames)
            var managerCLI = AgentCLI.claude
            if case .cli(let chosen) = managerProgram { managerCLI = chosen }
            var manager = AgentNode(
                sessionName: allocator.allocate(TmuxName.sanitize(trimmed)),
                displayName: trimmed,
                kind: .manager,
                roleTitle: "Plans and reviews",
                cli: managerCLI,
                workingDirectory: directory)
            // The shipped prompts can have been deleted; use one that exists.
            manager.promptTemplateID = model.validTemplateID(for: manager)
            model.addTeam(Topology(name: trimmed, nodes: [manager]))
            // Straight to the canvas, which is where the rest of the team is added.
            model.mode = .topology
            model.inspectedNodeID = manager.id
        }
        dismiss()
    }
}

/// Saves the current team's shape for reuse.
struct SaveTemplateSheet: View {
    @Bindable var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save team shape")
                .font(.title3.weight(.semibold))
            Text("Creating a team from this shape makes fresh agents with new session names. "
                + "It never reuses the ones running now.")
                .font(.callout)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    env.model.saveSelectedTeamAsTemplate(named: name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            env.isModalPresented = true
            if name.isEmpty { name = env.model.selectedTopology?.name ?? "Team shape" }
        }
        .onDisappear { env.isModalPresented = false }
    }
}

/// Attaches one of the machine's existing sessions to the selected agent.
struct AttachSessionSheet: View {
    @Bindable var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?

    private var model: AppModel { env.model }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Attach an existing session")
                .font(.title3.weight(.semibold))
            if let node = model.selectedNode {
                Text("The session you pick becomes \(node.displayName). Marmy sends it nothing — "
                    + "no prompt, no keystrokes — it just connects to it.")
                    .font(.callout)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            List(selection: $selection) {
                ForEach(model.unassignedSessions, id: \.id) { session in
                    HStack(spacing: 8) {
                        Image(systemName: "terminal").foregroundStyle(Theme.muted)
                        Text(session.name)
                        Spacer()
                        Text(session.id)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Theme.muted)
                    }
                    .tag(session.id)
                }
            }
            .frame(height: 220)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Attach") {
                    if let selection, let nodeID = model.selectedNodeID {
                        Task { await model.adopt(sessionID: selection, into: nodeID) }
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil || model.selectedNodeID == nil)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { env.isModalPresented = true }
        .onDisappear { env.isModalPresented = false }
    }
}

/// The keyboard reference, also in the Help menu.
struct ShortcutsView: View {
    @Environment(\.dismiss) private var dismiss

    private let rows: [(String, String)] = [
        ("⌃⇥", "Next agent at this level — top-level agents cycle across every team"),
        ("⌃⇧⇥", "Previous agent at this level"),
        ("⌘↑", "Go to the manager"),
        ("⌘↓", "Go to the last report you were in"),
        ("Hold Space", "Dictate — the words go into the agent's own prompt when you let go"),
        ("Tap Space", "An ordinary space in the terminal"),
        ("↩", "Sends what is at the agent's prompt. Marmy never presses it for you"),
        ("⌘V", "Paste. A screenshot is saved and its path typed, without Return"),
        ("⌘R", "Start the selected agent"),
        ("⌘1 / ⌘2", "Work view / Topology view"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keyboard").font(.title3.weight(.semibold))
            ForEach(rows, id: \.0) { row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(row.0)
                        .font(.system(.callout, design: .monospaced))
                        .frame(width: 92, alignment: .leading)
                        .foregroundStyle(Theme.ink)
                    Text(row.1)
                        .font(.callout)
                        .foregroundStyle(Theme.muted)
                }
            }
            Text("There is one place to type: the agent's own terminal. Dictation, pasted images "
                + "and team updates all arrive there, and nothing is ever sent without you.")
                .font(.caption)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Text("Hierarchy shortcuts work in the work view, including while the terminal has focus. "
                + "They stay out of the way while you are typing in a field.")
            Text("An agent with no manager is a top-level agent: its peers are the top-level agents of "
                + "every team, so ⌃⇥ moves between the orchestrators you are running. An agent that "
                + "reports to someone cycles only among that manager's reports.")
                .font(.caption)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
