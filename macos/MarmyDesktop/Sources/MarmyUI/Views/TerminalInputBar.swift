import AppKit
import MarmyCore
import SwiftUI

/// The strip under the terminal.
///
/// There is no second place to type: you type in the terminal, and you press
/// Enter there. This shows how to dictate, what is being heard while you hold
/// Space, and — if words could not be put into the prompt — offers them back
/// rather than losing them.
struct TerminalInputBar: View {
    @Bindable var env: AppEnvironment
    let target: WorkTarget

    @State private var isExpanded = false

    private var model: AppModel { env.model }
    private var isDictatingHere: Bool { env.voice.isCapturing(for: target) }

    var body: some View {
        VStack(spacing: 0) {
            if let pending = env.dictation.item(for: target) {
                pendingStrip(pending)
                Divider()
            }
            HStack(spacing: 10) {
                micButton
                content
                Spacer(minLength: 8)
                status
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .background(Theme.surface)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Middle

    @ViewBuilder
    private var content: some View {
        if isDictatingHere {
            // What is being heard, as it is heard, following the latest words.
            // Not editable: it goes into the agent's own prompt when you let go,
            // and you edit it there.
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 0) {
                        Text(env.voice.preview.isEmpty ? "Listening…" : env.voice.preview)
                            .font(.body)
                            .foregroundStyle(env.voice.preview.isEmpty ? Theme.muted : Theme.ink)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        // An anchor of its own after the text: scrolling to the
                        // text scrolls to where the text ended last layout,
                        // which is short of the words just added.
                        Color.clear
                            .frame(height: 1)
                            .id(Self.previewTailID)
                    }
                }
                .frame(maxHeight: 66)
                .onChange(of: env.voice.preview, initial: true) { _, _ in
                    // Once now, and once after this layout pass: the anchor only
                    // moves down when the taller text has been measured.
                    proxy.scrollTo(Self.previewTailID, anchor: .bottom)
                    DispatchQueue.main.async {
                        proxy.scrollTo(Self.previewTailID, anchor: .bottom)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 6) {
                Text("Type in the terminal.")
                    .font(.callout)
                    .foregroundStyle(Theme.muted)
                Text("Hold Space to dictate")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.ink)
                Text("— it goes into the prompt for you to send.")
                    .font(.callout)
                    .foregroundStyle(Theme.muted)
            }
            .lineLimit(1)
        }
    }

    private static let previewTailID = "marmy.voice.preview.tail"

    // MARK: - Status

    @ViewBuilder
    private var status: some View {
        HStack(spacing: 8) {
            if isDictatingHere {
                HStack(spacing: 5) {
                    Circle().fill(Theme.danger).frame(width: 6, height: 6)
                    Text(env.voice.status == .listening ? "Release to paste" : (env.voice.status.message ?? ""))
                        .font(.caption)
                        .foregroundStyle(Theme.ink)
                    Text(env.voice.isOnDevice ? "on this Mac" : "via Apple's servers")
                        .font(.caption2)
                        .foregroundStyle(Theme.muted)
                }
            } else if let message = env.voice.status.message, env.voice.target == nil {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(voiceMessageColor)
                    .lineLimit(2)
                if case .unavailable = env.voice.status, let pane = env.voice.settingsPane {
                    Button(pane.title) {
                        if let url = pane.url { NSWorkspace.shared.open(url) }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
            if let notice = env.voice.notice {
                Text(notice)
                    .font(.caption2)
                    .foregroundStyle(Theme.warning)
                    .lineLimit(2)
            }
        }
    }

    private var voiceMessageColor: Color {
        switch env.voice.status {
        case .failed, .unavailable: return Theme.danger
        default: return Theme.muted
        }
    }

    // MARK: - Microphone

    private var micButton: some View {
        Image(systemName: isDictatingHere ? "mic.fill" : "mic")
            .font(.system(size: 13))
            .foregroundStyle(isDictatingHere ? Theme.danger : Theme.muted)
            .frame(width: 26, height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isDictatingHere ? Theme.danger.opacity(0.12) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line, lineWidth: 1))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !env.voice.isCapturing else { return }
                        env.micPressed()
                    }
                    .onEnded { _ in env.micReleased() })
            .accessibilityLabel("Hold to dictate")
            .help("Press and hold to dictate, or hold Space with the terminal focused. "
                + "Marmy asks for microphone permission the first time.")
    }

    // MARK: - Words waiting to be delivered

    private func pendingStrip(_ pending: PendingDictation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol(for: pending.state))
                    .foregroundStyle(tint(for: pending.state))
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline(for: pending.state))
                        .font(.callout)
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if case .uncertain = pending.state {
                        Text("Look at the terminal first: these words may already be in the prompt.")
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                    }
                }
                Spacer(minLength: 8)
                buttons(for: pending)
            }
            // The whole transcript, scrollable, so nothing is hidden behind an
            // ellipsis while you decide what to do with it.
            ScrollView(.vertical) {
                Text(pending.text)
                    .font(.system(.callout, design: .default))
                    .foregroundStyle(Theme.muted)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: isExpanded ? 200 : 54)
            .overlay(alignment: .bottomTrailing) {
                Button(isExpanded ? "Show less" : "Show all") { isExpanded.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
                    .padding(.trailing, 2)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(tint(for: pending.state).opacity(0.08))
    }

    @ViewBuilder
    private func buttons(for pending: PendingDictation) -> some View {
        switch pending.state {
        case .pasting:
            ProgressView().controlSize(.small)
        case .failed:
            Button("Try again") { Task { await env.retryDictation(pending.id) } }
            copyButton(pending.text)
            Button("Discard", role: .destructive) { env.discardDictation(pending.id) }
        case .uncertain:
            // No blind retry: repeating a long prompt is worse than pausing.
            copyButton(pending.text)
            Button("Paste again anyway") { Task { await env.retryDictation(pending.id) } }
                .help("Only after checking the terminal — this may put the words in twice.")
            Button("Discard", role: .destructive) { env.discardDictation(pending.id) }
        }
    }

    private func copyButton(_ text: String) -> some View {
        Button("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    private func symbol(for state: PendingDictation.State) -> String {
        switch state {
        case .pasting: return "waveform"
        case .failed: return "exclamationmark.triangle.fill"
        case .uncertain: return "questionmark.circle.fill"
        }
    }

    private func tint(for state: PendingDictation.State) -> Color {
        switch state {
        case .pasting: return Theme.muted
        case .failed: return Theme.warning
        case .uncertain: return Theme.warning
        }
    }

    private func headline(for state: PendingDictation.State) -> String {
        switch state {
        case .pasting: return "Putting it in the prompt…"
        case .failed(let reason): return reason
        case .uncertain(let reason): return reason
        }
    }
}
