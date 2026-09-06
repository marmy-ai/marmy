import MarmyCore
import SwiftUI

/// The per-agent draft, dictation, and Send.
///
/// The draft belongs to the target it was written for: switching agents leaves
/// it where it is, and a message can only be sent to the agent whose draft it
/// is.
struct ComposerView: View {
    @Bindable var env: AppEnvironment
    let target: WorkTarget
    @FocusState private var editorFocused: Bool

    private var model: AppModel { env.model }

    private var draft: Binding<String> {
        Binding(
            get: { model.drafts.text(for: target) },
            set: { model.drafts.setText($0, for: target) })
    }

    /// True while dictation is running *or* finishing for this target: a final
    /// transcript can still replace the text, so typing must not fight it.
    private var isDictatingHere: Bool {
        model.drafts.isDictating(target) || (env.voice.target == target && env.voice.isCapturing)
    }

    private var isSending: Bool { env.isSending(target) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: draft)
                    .font(.system(.body, design: .default))
                    .scrollContentBackground(.hidden)
                    .background(Theme.surface)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                    .frame(height: 56)
                    .focused($editorFocused)
                    // While a transcript is being written, typing would fight the
                    // recogniser for the same text.
                    .disabled(isDictatingHere)
                if model.drafts.isEmpty(target) && !isDictatingHere {
                    Text(placeholder)
                        .font(.body)
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 19)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }

            HStack(spacing: 10) {
                micButton
                voiceStatus
                Spacer(minLength: 8)
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                Button {
                    send()
                } label: {
                    if isSending {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Send")
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(model.drafts.isEmpty(target) || isSending || isDictatingHere)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .background(Theme.surface)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var placeholder: String {
        switch target {
        case .node:
            return "Message this agent. Hold Space in the terminal to dictate."
        case .localSession:
            return "Message this session. Hold Space in the terminal to dictate."
        }
    }

    private var hint: String {
        isDictatingHere ? "Release Space to finish" : "⌘↩ to send"
    }

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
            .help("Press and hold to dictate. Marmy asks for microphone permission the first time.")
    }

    @ViewBuilder
    private var voiceStatus: some View {
        if let message = env.voice.status.message, env.voice.target == target || !env.voice.isCapturing {
            HStack(spacing: 6) {
                if isDictatingHere {
                    Circle().fill(Theme.danger).frame(width: 6, height: 6)
                }
                Text(message)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .lineLimit(2)
                if isDictatingHere {
                    Text(env.voice.isOnDevice ? "on this Mac" : "via Apple's servers")
                        .font(.caption2)
                        .foregroundStyle(Theme.muted)
                }
                if case .unavailable = env.voice.status, let pane = env.voice.settingsPane {
                    Button(pane.title) {
                        if let url = pane.url { NSWorkspace.shared.open(url) }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        }
    }

    private var statusColor: Color {
        switch env.voice.status {
        case .failed, .unavailable: return Theme.danger
        case .listening: return Theme.ink
        default: return Theme.muted
        }
    }

    private func send() {
        guard !model.drafts.isEmpty(target), !isDictatingHere, !isSending else { return }
        // The target this composer belongs to, captured before anything async.
        let origin = target
        Task { await env.sendDraft(from: origin) }
    }
}
