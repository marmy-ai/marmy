import AppKit
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

/// The app's own icon and name, at the left of the window's header.
///
/// The icon is the one the bundle carries — asked for, never drawn here — so it
/// is whatever Marmy is currently shipping. Outside a bundle (a `swift run`),
/// AppKit hands back a placeholder rather than nothing.
struct MarmyMark: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: Self.icon)
                .accessibilityHidden(true)
            Text("Marmy")
                .font(.headline)
                .foregroundStyle(Theme.ink)
                .fixedSize()
        }
        .accessibilityLabel("Marmy")
    }

    /// A copy of the app's icon at the size it is drawn.
    ///
    /// Drawn into its own image rather than resized with a modifier: AppKit
    /// containers read an `NSImage`'s own size and ignore what SwiftUI asked
    /// for, and the bundle's icon is 512 points square. The shared icon is
    /// never touched — mutating it would change the Dock's.
    static let icon: NSImage = {
        let source = NSApp.applicationIconImage ?? NSImage(size: NSSize(width: 18, height: 18))
        let size = NSSize(width: 18, height: 18)
        let copy = NSImage(size: size)
        copy.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(
            in: NSRect(origin: .zero, size: size),
            from: .zero, operation: .sourceOver, fraction: 1)
        copy.unlockFocus()
        return copy
    }()
}

/// Names the window without drawing the name in the header.
///
/// A title drawn in the toolbar repeats the team menu beside it and takes the
/// room the buttons need — at the minimum window width, "Start team" was being
/// pushed into the overflow. The window still has to have a name for the Window
/// menu, Mission Control and accessibility, so the name is set and only its
/// drawing is turned off.
struct WindowTitle: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        apply(from: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        apply(from: view)
    }

    private func apply(from view: NSView) {
        let title = title
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.title = title
            // The name stays; only the drawn copy of it goes.
            window.titleVisibility = .hidden
        }
    }
}

/// What you can do to one agent, from wherever you can see it.
///
/// Small on purpose: add someone under it, edit it, remove it. Anything rarer
/// belongs in the inspector, where there is room to explain it.
struct NodeMenu: View {
    @Bindable var env: AppEnvironment
    let nodeID: UUID

    private var model: AppModel { env.model }

    var body: some View {
        Button("Add worker here") { add(.worker) }
        Button("Add manager here") { add(.manager) }
        Divider()
        Button("Edit agent") {
            model.inspectedNodeID = nodeID
            env.select(node: nodeID)
            model.mode = .topology
        }
        Divider()
        Button("Delete agent", role: .destructive) {
            Task { await model.deleteNode(nodeID) }
        }
    }

    /// Under this agent, whatever it is and whichever team it is in. A worker
    /// leading two of its own is an ordinary shape.
    private func add(_ kind: AgentKind) {
        guard model.addNode(kind: kind, parentID: nodeID) != nil else { return }
        // The new agent needs somewhere to be edited, and that is the graph.
        model.mode = .topology
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
