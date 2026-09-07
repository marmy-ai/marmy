import MarmyCore
import MarmyRuntime
import SwiftUI

extension AgentKind {
    var tint: Color {
        switch self {
        case .manager: return Theme.manager
        case .worker: return Theme.worker
        }
    }
}

/// The small coloured dot that says manager or worker.
struct KindDot: View {
    let kind: AgentKind
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(kind.tint)
            .frame(width: size, height: size)
            .accessibilityLabel(kind.displayName)
    }
}

/// Quiet status text with a leading dot.
struct StatusPill: View {
    let connection: TargetConnection

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(connection.label)
                .font(.callout)
                .foregroundStyle(Theme.muted)
        }
        .help(connection.detail ?? connection.label)
    }

    private var color: Color {
        switch connection {
        case .attached: return Theme.worker
        case .starting: return Theme.warning
        case .failed: return Theme.danger
        case .ended: return Theme.muted
        case .notStarted: return Theme.line
        }
    }
}

struct BannerView: View {
    let banner: Banner
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(banner.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.ink)
                if let detail = banner.detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.muted)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(tint.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var symbol: String {
        switch banner.kind {
        case .info: return "info.circle"
        case .success: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .failure: return "xmark.octagon"
        }
    }

    private var tint: Color {
        switch banner.kind {
        case .info: return Theme.manager
        case .success: return Theme.worker
        case .warning: return Theme.warning
        case .failure: return Theme.danger
        }
    }
}

/// A file that arrived but never reached a prompt.
///
/// It is on disk either way, so the banner hands it over rather than
/// apologising: the path can be copied, or shown in the Finder.
struct RecoveredAttachmentBanner: View {
    let path: String
    let copy: () -> Void
    let reveal: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "paperclip.badge.ellipsis")
                .foregroundStyle(Theme.warning)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("That file was kept")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.ink)
                Text(path)
                    .font(.callout.monospaced())
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button("Copy path", action: copy)
            Button("Show in Finder", action: reveal)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.muted)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(Theme.warning.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// A centred message for a place with nothing in it yet.
struct EmptyStateView<Actions: View>: View {
    let title: String
    let message: String
    var symbol: String = "point.3.connected.trianglepath.dotted"
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.muted)
            Text(title)
                .font(.title3.weight(.medium))
                .foregroundStyle(Theme.ink)
            Text(message)
                .font(.callout)
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: 10) { actions }
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

/// Field label used across the inspector and sheets.
struct FieldLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(Theme.muted)
            .frame(width: 108, alignment: .leading)
    }
}

struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            FieldLabel(text: label)
            content
        }
    }
}

extension ValidationIssue.Severity {
    var tint: Color {
        self == .error ? Theme.danger : Theme.warning
    }
}
