import AppKit
import Foundation

/// Keyboard handling for the work area: hierarchy navigation and hold-to-talk.
///
/// The monitor is app-local — `addLocalMonitorForEvents` only ever sees this
/// app's own events, never another app's. Nothing is consumed while a sheet is
/// up or while the user is typing in a field, and a short tap of Space still
/// reaches the terminal as an ordinary space.
@MainActor
public final class KeyboardCoordinator {
    public enum Navigation: Equatable, Sendable {
        case nextPeer
        case previousPeer
        case parent
        case child
    }

    /// What the app looks like at the moment an event arrives.
    public struct Context: Equatable, Sendable {
        public var isWorkMode: Bool
        public var terminalHasFocus: Bool
        public var isEditingText: Bool
        public var isModalPresented: Bool

        public init(
            isWorkMode: Bool = true,
            terminalHasFocus: Bool = false,
            isEditingText: Bool = false,
            isModalPresented: Bool = false
        ) {
            self.isWorkMode = isWorkMode
            self.terminalHasFocus = terminalHasFocus
            self.isEditingText = isEditingText
            self.isModalPresented = isModalPresented
        }
    }

    public static let spaceKeyCode: UInt16 = 49
    public static let tabKeyCode: UInt16 = 48
    public static let upArrowKeyCode: UInt16 = 126
    public static let downArrowKeyCode: UInt16 = 125

    /// How long Space must be held before it means "dictate" instead of "space".
    public var holdDelay: TimeInterval = 0.2

    public var context: () -> Context = { Context() }
    public var onNavigate: (Navigation) -> Void = { _ in }
    public var onHoldBegan: () -> Void = {}
    public var onHoldEnded: () -> Void = {}
    /// A short tap: the terminal should receive a plain space.
    public var onSpaceTap: () -> Void = {}
    /// Swapped out in tests so hold timing is deterministic.
    public var schedule: (TimeInterval, @escaping () -> Void) -> Void = { delay, body in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: body)
    }

    private enum SpaceState: Equatable {
        case idle
        case pending(token: Int)
        case holding(token: Int)
    }

    private var spaceState: SpaceState = .idle
    private var nextToken = 0
    private var monitor: Any?

    public init() {}

    public var isHolding: Bool {
        if case .holding = spaceState { return true }
        return false
    }

    public var isWaitingForHold: Bool {
        if case .pending = spaceState { return true }
        return false
    }

    // MARK: - Event handling

    /// Returns true when the event was consumed and must not travel further.
    @discardableResult
    public func handleKeyDown(code: UInt16, modifiers: NSEvent.ModifierFlags, isRepeat: Bool) -> Bool {
        let context = context()
        guard !context.isModalPresented else { return false }

        let relevant = modifiers.intersection([.command, .control, .option, .shift])

        // Fast typing rolls one key over the next: Space down, B down, Space up.
        // The waiting space has to reach the terminal before the B does, or the
        // user sees "b " where they typed " b".
        if code != Self.spaceKeyCode, isWaitingForHold {
            flushPendingSpace()
        }

        if code == Self.tabKeyCode, relevant.contains(.control), context.isWorkMode {
            onNavigate(relevant.contains(.shift) ? .previousPeer : .nextPeer)
            return true
        }
        // Command-Up and Command-Down move the caret in a text field. They only
        // mean "manager" and "reports" outside one.
        if code == Self.upArrowKeyCode, relevant == [.command], context.isWorkMode, !context.isEditingText {
            onNavigate(.parent)
            return true
        }
        if code == Self.downArrowKeyCode, relevant == [.command], context.isWorkMode, !context.isEditingText {
            onNavigate(.child)
            return true
        }

        guard code == Self.spaceKeyCode, relevant.isEmpty else { return false }
        // Auto-repeat while a hold is running must not start a second capture,
        // and must not leak spaces into the terminal.
        if isRepeat { return spaceState != .idle }
        guard context.isWorkMode, context.terminalHasFocus, !context.isEditingText else { return false }
        guard spaceState == .idle else { return true }

        nextToken += 1
        let token = nextToken
        spaceState = .pending(token: token)
        schedule(holdDelay) { [weak self] in
            self?.holdTimerFired(token: token)
        }
        return true
    }

    @discardableResult
    public func handleKeyUp(code: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard code == Self.spaceKeyCode else { return false }
        switch spaceState {
        case .idle:
            return false
        case .pending:
            // Too quick to be a hold: this was someone typing a space.
            spaceState = .idle
            onSpaceTap()
            return true
        case .holding:
            spaceState = .idle
            onHoldEnded()
            return true
        }
    }

    /// Emits the space that was waiting to become a hold, and stops waiting.
    private func flushPendingSpace() {
        guard case .pending = spaceState else { return }
        spaceState = .idle
        onSpaceTap()
    }

    /// Stops a capture for a reason other than the key coming up.
    public func cancelHold() {
        switch spaceState {
        case .idle:
            return
        case .pending:
            spaceState = .idle
        case .holding:
            spaceState = .idle
            onHoldEnded()
        }
    }

    func holdTimerFired(token: Int) {
        guard case .pending(let pending) = spaceState, pending == token else { return }
        let context = context()
        // Focus can move during the delay; a hold only belongs to the work area.
        guard context.isWorkMode, context.terminalHasFocus, !context.isEditingText, !context.isModalPresented else {
            spaceState = .idle
            return
        }
        spaceState = .holding(token: token)
        onHoldBegan()
    }

    // MARK: - Installation

    public func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            let consumed: Bool
            switch event.type {
            case .keyDown:
                consumed = self.handleKeyDown(
                    code: event.keyCode, modifiers: event.modifierFlags, isRepeat: event.isARepeat)
            case .keyUp:
                consumed = self.handleKeyUp(code: event.keyCode, modifiers: event.modifierFlags)
            default:
                consumed = false
            }
            return consumed ? nil : event
        }
    }

    public func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
