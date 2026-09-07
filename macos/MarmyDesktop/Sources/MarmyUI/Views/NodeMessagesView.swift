import MarmyCore
import MarmyRuntime
import SwiftUI

/// What Marmy has actually said to one agent, and what is waiting to be said.
///
/// Everything below the waiting list is a record of something handed over: the
/// exact text, in full, with where it went and what became of it. Nothing here
/// is a preview — the prompt a *future* launch would send is shown in the
/// inspector and labelled as such — and nothing here is editable. Marmy has one
/// place to type, and it is the terminal.
struct NodeMessagesView: View {
    @Bindable var env: AppEnvironment
    let nodeID: UUID

    @State private var expanded: Set<UUID> = []

    private var entries: [JournalEntry] { env.messages[nodeID] ?? [] }
    private var waiting: [RosterCoordinator.Pending] { env.roster.pendingItems(forNode: nodeID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !waiting.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Waiting to be sent")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.warning)
                    ForEach(waiting) { item in
                        pendingRow(item)
                    }
                }
            }

            history

            if entries.isEmpty {
                Text(emptyExplanation)
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(entries.reversed()) { entry in
                    entryRow(entry)
                }
            }
        }
        .task(id: nodeID) { await env.loadMessages(for: nodeID) }
        .task(id: env.journalRevision) { await env.loadMessages(for: nodeID) }
    }

    // MARK: - History

    @ViewBuilder
    private var history: some View {
        if env.priorHistoryIsUnknown(nodeID) {
            Text(env.isAdopted(nodeID)
                ? "Marmy did not start this session: it was already running when it was attached. "
                    + "Whatever it was told before that, Marmy has no record of."
                : "Marmy started this session, but has no record of what it was sent — it was "
                    + "started before Marmy kept one. Only messages listed here can be accounted for.")
                .font(.caption)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyExplanation: String {
        env.priorHistoryIsUnknown(nodeID)
            ? "No recorded messages for this session."
            : "No recorded messages for this session. Marmy has not sent this agent anything."
    }

    // MARK: - Rows

    @ViewBuilder
    private func pendingRow(_ item: RosterCoordinator.Pending) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(item.isUnconfirmed ? "Delivery not confirmed" : "Not sent yet")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(item.isUnconfirmed ? Theme.warning : Theme.ink)
                Spacer(minLength: 4)
            }
            Text(item.reason.isEmpty ? "Waiting." : item.reason)
                .font(.caption)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            fullText(item.entry.payload)
            HStack(spacing: 8) {
                if item.isUnconfirmed {
                    // Never "Send now": nobody knows whether the agent already
                    // has it, so the button says what it would really do.
                    Button("Send again anyway") { Task { await env.roster.sendNow(item.id) } }
                        .help("Only after looking at the terminal — the agent may have this already, "
                            + "and it would arrive twice.")
                    Button("Copy") { env.copy(item.entry.payload) }
                    Button("Dismiss") { Task { await env.roster.discard(item.id) } }
                        .help("Takes it off this list. What became of the delivery stays on record.")
                } else {
                    Button("Send now") { Task { await env.roster.sendNow(item.id) } }
                        .help("Sends it whatever the agent is doing. It lands wherever the cursor is.")
                    Button("Copy") { env.copy(item.entry.payload) }
                    Button("Throw away", role: .destructive) {
                        Task { await env.roster.discard(item.id) }
                    }
                }
            }
            .font(.caption)
            .disabled(item.isSending)
        }
        .padding(8)
        .background(Theme.warning.opacity(0.07))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line, lineWidth: 1))
    }

    @ViewBuilder
    private func entryRow(_ entry: JournalEntry) -> some View {
        let isExpanded = expanded.contains(entry.id)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(Self.title(of: entry.kind))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.ink)
                Text(Self.describe(entry.status))
                    .font(.caption)
                    .foregroundStyle(Self.tint(entry.status))
                Spacer(minLength: 4)
                Text(entry.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(Theme.muted)
            }
            Text(Self.destination(of: entry))
                .font(.caption2.monospaced())
                .foregroundStyle(Theme.muted)
            if let detail = entry.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isExpanded {
                fullText(entry.payload)
            } else {
                Text(entry.payload)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button(isExpanded ? "Hide full message" : "Show full message") {
                    if isExpanded { expanded.remove(entry.id) } else { expanded.insert(entry.id) }
                }
                Button("Copy") { env.copy(entry.payload) }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// The whole message, exactly as it was handed over, scrollable and
    /// selectable — never trimmed to fit.
    @ViewBuilder
    private func fullText(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
        }
        .frame(maxHeight: 220)
        .background(Theme.paper)
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line, lineWidth: 1))
    }

    // MARK: - Words

    static func title(of kind: JournalEntry.Kind) -> String {
        switch kind {
        case .launchPrompt: return "Starting prompt"
        case .dictation: return "Dictation"
        case .rosterUpdate: return "Team update"
        case .userMessage: return "Your message"
        }
    }

    /// Where it went, as it was at the time.
    static func destination(of entry: JournalEntry) -> String {
        var pieces: [String] = []
        if !entry.sessionName.isEmpty { pieces.append(entry.sessionName) }
        if !entry.sessionID.isEmpty { pieces.append(entry.sessionID) }
        if !entry.paneID.isEmpty { pieces.append("pane \(entry.paneID)") }
        if let generation = entry.generation {
            pieces.append("launch \(generation.uuidString.prefix(8).lowercased())")
        }
        return pieces.isEmpty ? "no recorded destination" : pieces.joined(separator: " · ")
    }

    /// Said plainly, and never claiming more than Marmy knows: handing text to
    /// tmux is not the same as an agent reading it.
    static func describe(_ status: JournalEntry.Status) -> String {
        switch status {
        case .prepared: return "waiting to be sent"
        // Nothing has confirmed this one. While it is genuinely in flight that
        // is true as well, and a moment later it says something else.
        case .sending: return "delivery not confirmed"
        case .superseded: return "replaced before it was sent"
        case .discarded: return "thrown away before it was sent"
        case .pasted: return "put into the prompt, not sent"
        case .submitted: return "delivered"
        case .failed: return "not sent"
        case .uncertain: return "delivery not confirmed"
        }
    }

    static func tint(_ status: JournalEntry.Status) -> Color {
        switch status {
        case .submitted, .pasted: return Theme.worker
        case .failed: return Theme.danger
        case .uncertain, .prepared, .sending: return Theme.warning
        case .superseded, .discarded: return Theme.muted
        }
    }
}

/// The message history for one agent, in a window of its own.
struct MessagesSheet: View {
    @Bindable var env: AppEnvironment
    let nodeID: UUID
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Messages to \(title)")
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                    Text("What Marmy has said to this agent, exactly as it was sent. "
                        + "To say something yourself, type in its terminal.")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
            Divider()
            ScrollView {
                NodeMessagesView(env: env, nodeID: nodeID)
                    .padding(16)
            }
        }
        .frame(width: 660, height: 520)
        .background(Theme.surface)
    }
}
