import AppKit
import SwiftTerm
import SwiftUI

/// Puts an already-attached terminal into SwiftUI.
///
/// The view is owned by `TerminalController`, not by SwiftUI: `makeNSView` only
/// adopts it and `updateNSView` does nothing, so a state change anywhere in the
/// app cannot restart a live terminal.
struct TerminalHostView: NSViewRepresentable {
    let terminal: LocalProcessTerminalView
    /// Focus the terminal when it is first mounted, so typing goes to the agent
    /// without a click.
    let focusOnAppear: Bool

    func makeNSView(context: Context) -> NSView {
        let container = TerminalContainerView()
        container.adopt(terminal, focus: focusOnAppear)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let container = nsView as? TerminalContainerView else { return }
        // Adopting the same view again only re-lays it out. A different view
        // means the selection moved, and that one should take focus.
        container.adopt(terminal, focus: focusOnAppear)
    }
}

/// Holds the terminal at full size and keeps it sized through layout changes.
final class TerminalContainerView: NSView {
    private weak var terminal: NSView?

    func adopt(_ view: NSView, focus: Bool) {
        guard terminal !== view else {
            layoutTerminal()
            return
        }
        terminal?.removeFromSuperview()
        terminal = view
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = [.width, .height]
        view.frame = bounds
        addSubview(view)
        if focus { focusAfterMounting(view, attemptsLeft: 3) }
    }

    /// A freshly adopted terminal has no window for a moment; focus follows once
    /// it does.
    ///
    /// This only ever runs when a *different* terminal is adopted — the user
    /// moved to another agent — so taking focus is what they asked for. Routine
    /// updates re-adopt the same view and change nothing.
    private func focusAfterMounting(_ view: NSView, attemptsLeft: Int) {
        guard attemptsLeft > 0 else { return }
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self, let view, self.terminal === view else { return }
            guard let window = self.window else {
                self.focusAfterMounting(view, attemptsLeft: attemptsLeft - 1)
                return
            }
            window.makeFirstResponder(view)
        }
    }

    override func layout() {
        super.layout()
        layoutTerminal()
    }

    private func layoutTerminal() {
        guard let terminal, terminal.frame != bounds else { return }
        terminal.frame = bounds
    }

    override var acceptsFirstResponder: Bool { false }
}
