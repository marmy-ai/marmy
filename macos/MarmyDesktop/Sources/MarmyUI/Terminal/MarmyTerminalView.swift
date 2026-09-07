import AppKit
import SwiftTerm
import UniformTypeIdentifiers

/// Receiving a file another app has promised but not yet written.
public protocol PromisedFileReading {
    func receive(
        at destination: URL,
        queue: OperationQueue,
        completion: @escaping (URL?, Error?) -> Void)
}

/// AppKit's own promise receiver, behind that protocol.
struct FilePromiseReceiverAdapter: PromisedFileReading {
    let receiver: NSFilePromiseReceiver

    func receive(
        at destination: URL,
        queue: OperationQueue,
        completion: @escaping (URL?, Error?) -> Void
    ) {
        receiver.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: queue) {
            url, error in
            completion(url, error)
        }
    }
}

/// The terminal Marmy embeds.
///
/// Beyond the wheel, it handles the two things people expect a Mac terminal to
/// do with a screenshot: paste it, and drag it in. Both put the image on disk
/// and type its path at the prompt — no Enter, so the agent is not asked to do
/// anything until the user says so. Ordinary text paste is untouched.
public final class MarmyTerminalView: LocalProcessTerminalView {
    /// Where pasted images are written. Injectable for tests.
    public var attachments = AttachmentStore.default()
    /// The clipboard to read. Injectable so a test never has to touch the
    /// user's own.
    public var pasteboardProvider: () -> NSPasteboard = { .general }
    /// Asks the app to put text into this agent's prompt. It goes through the
    /// same identity checks and the same per-pane queue as everything else
    /// Marmy types, so a team update cannot land in the middle of a path.
    public var onInsertText: ((Insertion) -> Void)?

    /// Text on its way to a prompt, and the file it came from if there is one.
    ///
    /// The path travels with the text so that when the insertion fails the file
    /// is not lost with it: it is on disk, and the user can still be given it.
    public struct Insertion: Equatable, Sendable {
        public var text: String
        public var recoveredPath: String?

        public init(text: String, recoveredPath: String? = nil) {
            self.text = text
            self.recoveredPath = recoveredPath
        }

        /// Paths, quoted, with a space after them — the way a Finder drop puts
        /// them in. Without it a second dropped file joins the first into one
        /// name that matches nothing.
        public static func attachment(_ paths: [String]) -> Insertion {
            Insertion(
                text: paths.map(ShellQuoting.quote).joined(separator: " ") + " ",
                recoveredPath: paths.count == 1 ? paths[0] : nil)
        }
    }
    /// Told when an image could not be used, so the user hears about it. When a
    /// file was received but could not be handed over, its path comes too: the
    /// file is kept and the user can copy the path rather than losing it.
    public var onAttachmentFailure: ((AttachmentProblem) -> Void)?

    public struct AttachmentProblem: Equatable, Sendable {
        public var reason: String
        /// A file that exists and is still worth having.
        public var recoveredPath: String?

        public init(reason: String, recoveredPath: String? = nil) {
            self.reason = reason
            self.recoveredPath = recoveredPath
        }
    }

    /// How promised files are received. Injectable so the delayed-arrival paths
    /// can be tested without a drag from another app.
    public var promiseReaders: [any PromisedFileReading]?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .png, .tiff] + NSFilePromiseReceiver.readableDraggedTypes.map {
            NSPasteboard.PasteboardType($0)
        })
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL, .png, .tiff] + NSFilePromiseReceiver.readableDraggedTypes.map {
            NSPasteboard.PasteboardType($0)
        })
    }

    // MARK: - Paste

    public override func paste(_ sender: Any?) {
        let pasteboard = pasteboardProvider()
        switch handleAttachments(on: pasteboard) {
        case .handled, .refused:
            return
        case .notAttachment:
            // Ordinary text, including several lines: this is the user pasting
            // deliberately, and the terminal does what it always does.
            super.paste(sender)
        }
    }

    // MARK: - Drag and drop

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        canAccept(sender.draggingPasteboard) ? .copy : []
    }

    public override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        canAccept(sender.draggingPasteboard) ? .copy : []
    }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        // A screenshot dragged straight out of an app has no file yet: it is
        // promised, and arrives once it has been written.
        if receivePromisedFiles(from: sender) { return true }
        switch handleAttachments(on: pasteboard) {
        case .handled: return true
        case .refused: return false
        case .notAttachment: return false
        }
    }

    private func canAccept(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || pasteboard.data(forType: .png) != nil
            || pasteboard.data(forType: .tiff) != nil
            || pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
    }

    // MARK: - Attachments

    enum AttachmentOutcome {
        case handled
        case refused
        case notAttachment
    }

    /// Files and images on a pasteboard, as quoted paths.
    ///
    /// All or nothing: if one path in a drop cannot be typed safely, the whole
    /// drop is refused with a reason rather than half of it going in.
    func handleAttachments(on pasteboard: NSPasteboard) -> AttachmentOutcome {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
           !urls.isEmpty {
            let paths = urls.map(\.path)
            guard paths.allSatisfy(ShellQuoting.isTypable) else {
                onAttachmentFailure?(AttachmentProblem(reason:
                    "One of those file names cannot be typed at a prompt safely — it has a line break "
                        + "or a control character in it — so nothing was added."))
                return .refused
            }
            insert(.attachment(paths))
            return .handled
        }

        for (type, utType) in [(NSPasteboard.PasteboardType.png, UTType.png), (.tiff, .tiff)] {
            guard let data = pasteboard.data(forType: type) else { continue }
            // What it says it is, and what it actually is, are different
            // questions.
            guard NSBitmapImageRep(data: data) != nil else {
                onAttachmentFailure?(AttachmentProblem(
                    reason: "That clipboard image could not be read, so nothing was added."))
                return .refused
            }
            do {
                let url = try attachments.save(imageData: data, preferredType: utType)
                guard ShellQuoting.isTypable(url.path) else {
                    onAttachmentFailure?(AttachmentProblem(
                        reason: "The image was saved, but its path cannot be typed here.",
                        recoveredPath: url.path))
                    return .refused
                }
                insert(.attachment([url.path]))
                return .handled
            } catch {
                onAttachmentFailure?(AttachmentProblem(reason: "\(error)"))
                return .refused
            }
        }
        return .notAttachment
    }

    /// Files an app has promised but not yet written — a screenshot dragged out
    /// of Preview, say.
    ///
    /// Each promise gets a folder of its own — not each drop: one drop can carry
    /// two files called `Screenshot.png`, and neither may overwrite the other.
    /// The callbacks that will handle the file
    /// are taken now: by the time it arrives, this view may be showing a
    /// different agent, and the path must not go there.
    private func receivePromisedFiles(from sender: any NSDraggingInfo) -> Bool {
        let readers: [any PromisedFileReading]
        if let promiseReaders {
            readers = promiseReaders
        } else {
            let options: [NSPasteboard.ReadingOptionKey: Any] = [:]
            guard let receivers = sender.draggingPasteboard.readObjects(
                forClasses: [NSFilePromiseReceiver.self], options: options) as? [NSFilePromiseReceiver],
                !receivers.isEmpty
            else { return false }
            readers = receivers.map(FilePromiseReceiverAdapter.init)
        }

        // Captured now, not looked up later.
        let insert = onInsertText
        let report = onAttachmentFailure
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated

        for reader in readers {
            let destination: URL
            do {
                destination = try attachments.makeDropDirectory()
            } catch {
                report?(AttachmentProblem(reason: "\(error)"))
                continue
            }
            reader.receive(at: destination, queue: queue) { url, error in
                DispatchQueue.main.async {
                    if let error {
                        report?(AttachmentProblem(
                            reason: "That file could not be received: \(error.localizedDescription)"))
                        return
                    }
                    guard let url else { return }
                    guard ShellQuoting.isTypable(url.path) else {
                        report?(AttachmentProblem(
                            reason: "That file's name cannot be typed at a prompt.",
                            recoveredPath: url.path))
                        return
                    }
                    guard let insert else {
                        // The terminal it was dropped on is gone. The file is
                        // still here, and its path is worth keeping.
                        report?(AttachmentProblem(
                            reason: "That file arrived after its terminal went away, so it was not "
                                + "added. It is saved and you can copy the path.",
                            recoveredPath: url.path))
                        return
                    }
                    insert(.attachment([url.path]))
                }
            }
        }
        return true
    }

    /// Hands text to the app to put in the prompt. Never a newline: what to do
    /// with it is the user's decision.
    private func insert(_ insertion: Insertion) {
        guard !insertion.text.isEmpty else { return }
        if let onInsertText {
            onInsertText(insertion)
        } else {
            // No app to route through (a bare view in a test): type it here.
            send(source: self, data: ArraySlice(Array(insertion.text.utf8)))
        }
    }
}

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

        guard shouldReportScroll() else { return nil }

        // Some agents draw their own full-screen interface and ask for the
        // mouse; Claude does. For those the wheel belongs to the program, not to
        // tmux's scrollback — which for a full-screen pane is empty anyway. Hand
        // the event straight to SwiftTerm, which encodes it and writes it to the
        // connection already open: no process, and the agent scrolls its own
        // transcript. The mouse-mode check is what makes this safe, because it
        // is exactly the condition under which SwiftTerm reports rather than
        // falling back to arrow keys.
        if let view = terminal as? MarmyTerminalView,
           view.allowMouseReporting,
           !event.modifierFlags.contains(.shift),
           view.getTerminal().mouseMode != .off {
            view.scrollWheel(with: event)
            return nil
        }

        // Everything else: tmux's own scrollback, through the runtime.
        guard let lines = lines(for: event, in: terminal) else { return nil }
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
