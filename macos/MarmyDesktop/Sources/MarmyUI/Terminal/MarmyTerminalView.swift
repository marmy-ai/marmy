import AppKit
import SwiftTerm

/// The terminal Marmy embeds.
public final class MarmyTerminalView: LocalProcessTerminalView {}

/// Takes the scroll wheel away from the embedded terminal.
///
/// A tmux client runs on the alternate screen, and SwiftTerm's behaviour there
/// is "alternate scroll": every wheel line becomes an Up or Down key sent to
/// whatever is running in the pane. In a coding agent that walks its prompt
/// history — messages appearing and disappearing — while the real transcript,
/// which lives in tmux's own scrollback, never moves.
///
/// `TerminalView.scrollWheel` is public rather than open, so it cannot be
/// overridden from here. Instead this watches the app's own event stream, and
/// swallows wheel events over the terminal before they are ever delivered.
/// Nothing reaches the agent: no keys, no mouse reports. The gesture drives
/// Marmy's own history view, which reads the pane's real scrollback.
@MainActor
public final class TerminalScrollMonitor {
    /// The terminal currently on screen, if any.
    public var terminalView: () -> NSView? = { nil }
    /// Whether a swallowed gesture should open or move Marmy's history. The
    /// event is taken from the terminal either way — a sheet or a confirmation
    /// must not expose alternate scroll again.
    public var shouldReportScroll: () -> Bool = { true }
    /// Called with the number of lines scrolled; positive is upward.
    public var onScrollLines: (Int) -> Void = { _ in }
    /// The view an event would be delivered to. Injectable for tests.
    public var hitTest: (NSEvent, NSWindow) -> NSView? = { event, window in
        window.contentView?.hitTest(event.locationInWindow)
    }

    private var monitor: Any?
    private var accumulator: CGFloat = 0
    private static let assumedLineHeight: CGFloat = 16

    public init() {}

    public func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    public func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Returns `nil` when the event has been taken over, exactly as the event
    /// monitor does.
    ///
    /// The decision is made on the view the event would actually reach. Anything
    /// landing on the terminal — or on one of its subviews — is swallowed
    /// unconditionally, including while the history view is still being built,
    /// which is the window where a fast flick used to slip through and type
    /// arrows into the agent. Anything landing elsewhere, the history view's own
    /// scroll view included, is left alone.
    public func handle(_ event: NSEvent) -> NSEvent? {
        guard let terminal = terminalView(), let window = terminal.window else { return event }
        if let eventWindow = event.window, eventWindow !== window { return event }

        guard let hit = hitTest(event, window), hit === terminal || hit.isDescendant(of: terminal) else {
            return event
        }

        // Taken. Whether it also moves the history is a separate question.
        guard shouldReportScroll(), let lines = lines(for: event, in: terminal) else { return nil }
        onScrollLines(lines)
        return nil
    }

    /// Whole lines of movement, keeping the trackpad's leftover pixels.
    func lines(for event: NSEvent, in view: NSView?) -> Int? {
        guard event.scrollingDeltaY != 0 else { return nil }
        if event.hasPreciseScrollingDeltas {
            accumulator += event.scrollingDeltaY
            let height = lineHeight(in: view)
            let lines = Int(accumulator / height)
            accumulator -= CGFloat(lines) * height
            return lines == 0 ? nil : lines
        }
        accumulator = 0
        let rounded = Int(event.scrollingDeltaY.rounded())
        return rounded != 0 ? rounded : (event.scrollingDeltaY > 0 ? 1 : -1)
    }

    private func lineHeight(in view: NSView?) -> CGFloat {
        guard let terminal = view as? MarmyTerminalView else { return Self.assumedLineHeight }
        let rows = CGFloat(terminal.getTerminal().rows)
        guard rows > 0, terminal.bounds.height > 0 else { return Self.assumedLineHeight }
        return max(4, terminal.bounds.height / rows)
    }
}
