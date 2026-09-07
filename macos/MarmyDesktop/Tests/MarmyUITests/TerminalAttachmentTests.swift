import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import MarmyUI

/// Pasting and dropping files into a terminal, using a pasteboard of our own —
/// the user's clipboard is never touched.
@MainActor
final class TerminalAttachmentTests: XCTestCase {

    private var root: URL!
    private var pasteboard: NSPasteboard!
    private var view: MarmyTerminalView!
    private var inserted: [String] = []
    private var insertions: [MarmyTerminalView.Insertion] = []
    private var failures: [MarmyTerminalView.AttachmentProblem] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TerminalAttachmentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        pasteboard = NSPasteboard(name: NSPasteboard.Name("ai.marmy.tests.\(UUID().uuidString)"))
        inserted = []
        insertions = []
        failures = []

        view = MarmyTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.attachments = AttachmentStore(directoryURL: root.appendingPathComponent("pasted-images"))
        view.pasteboardProvider = { [unowned self] in self.pasteboard }
        view.onInsertText = { [unowned self] in
            self.inserted.append($0.text)
            self.insertions.append($0)
        }
        view.onAttachmentFailure = { [unowned self] in self.failures.append($0) }
    }

    override func tearDownWithError() throws {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
    }

    private func pngData() throws -> Data {
        let image = NSImage(size: NSSize(width: 6, height: 6))
        image.lockFocus()
        NSColor.systemPink.drawSwatch(in: NSRect(x: 0, y: 0, width: 6, height: 6))
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    func testAPastedScreenshotBecomesAQuotedPath() throws {
        pasteboard.clearContents()
        pasteboard.setData(try pngData(), forType: .png)

        view.paste(nil)

        XCTAssertEqual(inserted.count, 1)
        let inserted = try XCTUnwrap(self.inserted.first)
        XCTAssertTrue(inserted.hasSuffix("' "), "a space after it, as a Finder drop leaves: \(inserted)")
        let path = inserted.trimmingCharacters(in: .whitespaces)
        XCTAssertTrue(path.hasPrefix("'") && path.hasSuffix("'"), path)
        let file = String(path.dropFirst().dropLast())
        XCTAssertTrue(FileManager.default.fileExists(atPath: file), "the image is on disk for the agent to read")
        XCTAssertFalse(path.contains("\n"), "and no Enter is implied")
    }

    func testDraggedFilesAreUsedWhereTheyAreRatherThanCopied() throws {
        let existing = root.appendingPathComponent("already here.png")
        try (try pngData()).write(to: existing)
        pasteboard.clearContents()
        pasteboard.writeObjects([existing as NSURL])

        view.paste(nil)

        XCTAssertEqual(inserted, ["'\(existing.path)' "], "a file that exists is not duplicated")
        let saved = (try? FileManager.default.contentsOfDirectory(
            atPath: view.attachments.directoryURL.path)) ?? []
        XCTAssertTrue(saved.isEmpty)
    }

    func testSeveralFilesArriveAsSeveralQuotedPaths() throws {
        let first = root.appendingPathComponent("one.png")
        let second = root.appendingPathComponent("two shot.png")
        try (try pngData()).write(to: first)
        try (try pngData()).write(to: second)
        pasteboard.clearContents()
        pasteboard.writeObjects([first as NSURL, second as NSURL])

        view.paste(nil)

        XCTAssertEqual(inserted, ["'\(first.path)' '\(second.path)' "])
    }

    func testAnUnreadableImageIsRefusedAndSaidOutLoud() {
        pasteboard.clearContents()
        pasteboard.setData(Data("this is not a png".utf8), forType: .png)

        view.paste(nil)

        XCTAssertTrue(inserted.isEmpty, "nothing was typed")
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures[0].reason.contains("could not be read"))
    }

    func testOrdinaryTextPasteIsLeftToTheTerminal() {
        pasteboard.clearContents()
        pasteboard.setString("first line\nsecond line", forType: .string)

        // Deliberate text paste, multi-line included: the terminal handles it,
        // and Marmy does not turn it into an attachment.
        let outcome = view.handleAttachments(on: pasteboard)

        XCTAssertEqual(outcome, .notAttachment)
        XCTAssertTrue(inserted.isEmpty)
        XCTAssertTrue(failures.isEmpty)
    }

    func testAPromisedFileArrivingLateGoesToTheTerminalItWasDroppedOn() {
        // A screenshot dragged out of another app: the file does not exist yet.
        let promise = FakePromise()
        view.promiseReaders = [promise]
        let dropped = expectation(description: "promised file handled")

        XCTAssertTrue(view.performDragOperation(FakeDrag(pasteboard: pasteboard)))
        // It arrives later, by which time the view may be showing someone else.
        DispatchQueue.main.async { [self] in
            let destination = promise.destination!
            let file = destination.appendingPathComponent("Screenshot.png")
            try? Data("x".utf8).write(to: file)
            promise.completion?(file, nil)
            DispatchQueue.main.async { dropped.fulfill() }
        }
        wait(for: [dropped], timeout: 5)

        XCTAssertEqual(inserted.count, 1)
        XCTAssertTrue(inserted[0].contains("Screenshot.png"))
    }

    func testTwoPromisedFilesWithTheSameNameDoNotCollide() {
        var destinations: [URL] = []
        for _ in 0..<2 {
            let promise = FakePromise()
            view.promiseReaders = [promise]
            XCTAssertTrue(view.performDragOperation(FakeDrag(pasteboard: pasteboard)))
            destinations.append(promise.destination!)
        }

        XCTAssertNotEqual(destinations[0], destinations[1],
                          "each drop gets a folder of its own, so Screenshot.png survives")
    }

    func testTwoScreenshotsInOneDropBothSurvive() throws {
        // One drag, two promises, both called Screenshot.png.
        let first = FakePromise()
        let second = FakePromise()
        view.promiseReaders = [first, second]
        XCTAssertTrue(view.performDragOperation(FakeDrag(pasteboard: pasteboard)))

        let one = try XCTUnwrap(first.destination)
        let two = try XCTUnwrap(second.destination)
        XCTAssertNotEqual(one, two, "a folder each, within the one drop")

        let a = one.appendingPathComponent("Screenshot.png")
        let b = two.appendingPathComponent("Screenshot.png")
        try Data("first".utf8).write(to: a)
        try Data("second".utf8).write(to: b)
        let done = expectation(description: "both handled")
        first.completion?(a, nil)
        second.completion?(b, nil)
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 5)

        XCTAssertEqual(inserted.count, 2)
        XCTAssertEqual(try Data(contentsOf: a), Data("first".utf8),
                       "the first screenshot is still the first screenshot")
        XCTAssertEqual(try Data(contentsOf: b), Data("second".utf8))
    }

    func testTwoImagesPastedInARowStayTwoPaths() throws {
        pasteboard.clearContents()
        pasteboard.setData(try pngData(), forType: .png)
        view.paste(nil)
        pasteboard.clearContents()
        pasteboard.setData(try pngData(), forType: .png)
        view.paste(nil)

        // What the prompt ends up holding, in order.
        let line = inserted.joined()
        XCTAssertEqual(line.filter { $0 == "'" }.count, 4, "two quoted paths, not one: \(line)")
        XCTAssertFalse(line.contains("''"), "and they do not run together")
    }

    func testAnInsertionCarriesThePathSoAFailedPasteDoesNotLoseTheFile() throws {
        pasteboard.clearContents()
        pasteboard.setData(try pngData(), forType: .png)

        view.paste(nil)

        let insertion = try XCTUnwrap(insertions.first)
        let path = try XCTUnwrap(insertion.recoveredPath)
        XCTAssertEqual(insertion.text, ShellQuoting.quote(path) + " ")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path),
                      "so whoever handles a failed insertion can still hand over the file")
    }

    func testAPromisedFileGoesWhereItWasDroppedEvenIfTheViewMovesOn() {
        let promise = FakePromise()
        view.promiseReaders = [promise]
        XCTAssertTrue(view.performDragOperation(FakeDrag(pasteboard: pasteboard)))

        // The view is re-pointed at another agent while the file is in flight.
        var wrongPlace: [String] = []
        view.onInsertText = { wrongPlace.append($0.text) }

        let file = promise.destination!.appendingPathComponent("Late.png")
        try? Data("x".utf8).write(to: file)
        let done = expectation(description: "handled")
        promise.completion?(file, nil)
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 5)

        XCTAssertTrue(wrongPlace.isEmpty, "not to whatever the view points at now")
        XCTAssertEqual(inserted.count, 1, "to the terminal it was dropped on")
        XCTAssertTrue(inserted[0].contains("Late.png"))
    }

    func testAPromisedFileWithNowhereToGoIsKeptAndItsPathOffered() {
        // Dropped on a terminal that has no way to insert — the file still
        // arrives, and the path is worth keeping.
        view.onInsertText = nil
        let promise = FakePromise()
        view.promiseReaders = [promise]
        XCTAssertTrue(view.performDragOperation(FakeDrag(pasteboard: pasteboard)))

        let file = promise.destination!.appendingPathComponent("Orphan.png")
        try? Data("x".utf8).write(to: file)
        let done = expectation(description: "handled")
        promise.completion?(file, nil)
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 5)

        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.recoveredPath, file.path, "the file is kept and its path offered")
    }

    func testAnImageIsSavedOnceEvenIfItIsPastedTwice() throws {
        pasteboard.clearContents()
        pasteboard.setData(try pngData(), forType: .png)
        view.paste(nil)
        view.paste(nil)

        XCTAssertEqual(inserted.count, 2)
        XCTAssertNotEqual(inserted[0], inserted[1], "each paste keeps its own file")
        let saved = try FileManager.default.contentsOfDirectory(
            atPath: view.attachments.directoryURL.path)
        XCTAssertEqual(saved.count, 2, "and neither overwrites the other")
    }
}

/// A promise whose fulfilment the test decides.
@MainActor
final class FakePromise: PromisedFileReading {
    var destination: URL?
    var completion: ((URL?, Error?) -> Void)?

    nonisolated func receive(
        at destination: URL,
        queue: OperationQueue,
        completion: @escaping (URL?, Error?) -> Void
    ) {
        MainActor.assumeIsolated {
            self.destination = destination
            self.completion = completion
        }
    }
}

/// The little AppKit needs to hand us a drag.
final class FakeDrag: NSObject, NSDraggingInfo {
    let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }

    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var animatesToDestination: Bool = false
    var numberOfValidItemsForDrop: Int = 1
    var draggingFormation: NSDraggingFormation = .default
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    func resetSpringLoading() {}
}

extension MarmyTerminalView.AttachmentOutcome: @retroactive Equatable {
    public static func == (lhs: MarmyTerminalView.AttachmentOutcome, rhs: MarmyTerminalView.AttachmentOutcome) -> Bool {
        switch (lhs, rhs) {
        case (.handled, .handled), (.refused, .refused), (.notAttachment, .notAttachment): return true
        default: return false
        }
    }
}
