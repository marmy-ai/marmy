import AppKit
import MarmyRuntime
import SwiftUI

/// The scrollback view that opens when you scroll up in a terminal.
///
/// It shows what tmux is actually holding for that pane, read once and then held
/// still while you read it. The live terminal keeps running underneath: this
/// view sends nothing and changes nothing.
struct TerminalHistoryOverlay: View {
    @Bindable var env: AppEnvironment

    private var history: TerminalHistoryController { env.history }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Theme.terminalBackground)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(Theme.muted)
            VStack(alignment: .leading, spacing: 1) {
                Text("History")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.ink)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
            Button("Refresh") {
                Task { await history.refresh() }
            }
            .controlSize(.small)
            .disabled(history.isLoading)
            Button("Jump to live") {
                history.returnToLive()
                env.focusTerminal()
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .help("Escape also returns to the live terminal")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    private var subtitle: String {
        if history.isLoading { return "Reading the pane's scrollback…" }
        if let failure = history.failure { return failure }
        guard let snapshot = history.snapshot else { return "" }
        let time = snapshot.capturedAt.formatted(date: .omitted, time: .standard)
        var text = "\(snapshot.capturedLines) lines, read at \(time). "
            + "Output keeps arriving in the live terminal."
        if snapshot.isTruncated {
            text += " \(snapshot.omittedScrollbackLines) older lines are still in tmux but not shown."
        }
        return text
    }

    @ViewBuilder
    private var content: some View {
        if let failure = history.failure {
            EmptyStateView(
                title: "Could not read this pane's history",
                message: failure,
                symbol: "exclamationmark.triangle"
            ) {
                Button("Try again") { Task { await history.refresh() } }
                Button("Jump to live") { history.returnToLive() }
            }
        } else if let snapshot = history.snapshot {
            HistoryTextView(
                text: snapshot.text,
                linesFromBottom: history.initialLinesFromBottom)
        } else {
            // Focus lands here while the read is in flight, so keys typed in the
            // meantime cannot reach the agent hidden behind this view.
            ZStack {
                FocusCatcherView()
                ProgressView()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Read-only, selectable text with the terminal's colours.
///
/// It takes keyboard focus as it appears: the live terminal is still underneath,
/// and typing — or holding Space — while reading history must not reach the
/// agent. Selection, ⌘C, Page Up and Page Down are the text view's own.
private struct HistoryTextView: NSViewRepresentable {
    let text: String
    let linesFromBottom: Int

    final class Coordinator {
        /// The raw text last rendered, so a redraw does not re-parse a large
        /// transcript to discover nothing changed.
        var renderedSource: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(marmyHex: 0x121519)

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        render(into: textView, scrollView: scrollView, coordinator: context.coordinator, scrollToNearBottom: true)
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        guard context.coordinator.renderedSource != text else { return }
        render(into: textView, scrollView: scrollView, coordinator: context.coordinator, scrollToNearBottom: false)
    }

    private func render(
        into textView: NSTextView,
        scrollView: NSScrollView,
        coordinator: Coordinator,
        scrollToNearBottom: Bool
    ) {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textStorage?.setAttributedString(
            ANSIText.attributedString(from: text, font: font, defaultColor: NSColor(marmyHex: 0xE7ECF2)))
        coordinator.renderedSource = text

        guard scrollToNearBottom else { return }
        // Open where the eye already was: near the end, but not pinned to it, so
        // the first gesture does not look like nothing happened.
        DispatchQueue.main.async {
            if let container = textView.textContainer {
                textView.layoutManager?.ensureLayout(for: container)
            }
            let documentHeight = textView.frame.height
            let visibleHeight = scrollView.contentView.bounds.height
            let lineHeight = font.boundingRectForFont.height
            let offset = max(0, documentHeight - visibleHeight - CGFloat(max(linesFromBottom, 3)) * lineHeight)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }
}

/// Somewhere harmless for the keyboard to sit while history is loading.
private struct FocusCatcherView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = FocusCatcher()
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class FocusCatcher: NSView {
        override var acceptsFirstResponder: Bool { true }
    }
}
