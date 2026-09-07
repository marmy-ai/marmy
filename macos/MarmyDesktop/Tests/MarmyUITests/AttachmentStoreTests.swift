import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import MarmyUI

/// Screenshots pasted or dragged into a terminal.
final class AttachmentStoreTests: XCTestCase {

    private var root: URL!
    private var store: AttachmentStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttachmentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = AttachmentStore(directoryURL: root.appendingPathComponent("pasted-images"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func pngData(_ size: Int = 8) throws -> Data {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor.systemTeal.drawSwatch(in: NSRect(x: 0, y: 0, width: size, height: size))
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    func testAPastedImageIsSavedWhereOnlyYouCanReadIt() throws {
        let url = try store.save(imageData: try pngData(), preferredType: .png)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(url.pathExtension, "png")

        let fileMode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        let directoryMode = try FileManager.default
            .attributesOfItem(atPath: store.directoryURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(fileMode?.intValue, 0o600)
        XCTAssertEqual(directoryMode?.intValue, 0o700)
    }

    func testTIFFFromTheClipboardIsWrittenAsPNG() throws {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.drawSwatch(in: NSRect(x: 0, y: 0, width: 4, height: 4))
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)

        let url = try store.save(imageData: tiff, preferredType: .tiff)
        XCTAssertEqual(url.pathExtension, "png")
        XCTAssertNotNil(NSImage(contentsOf: url), "and it is a real image")
    }

    func testTwoPastesDoNotOverwriteEachOther() throws {
        let first = try store.save(imageData: try pngData(), preferredType: .png)
        let second = try store.save(imageData: try pngData(), preferredType: .png)

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path),
                      "an image an agent may still be about to read is not replaced")
    }

    func testNothingIsDeletedBehindTheAgentsBack() throws {
        let url = try store.save(imageData: try pngData(), preferredType: .png)
        // Anything else happening in the store leaves earlier files alone.
        _ = try store.save(imageData: try pngData(), preferredType: .png)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testSomethingThatIsNotAnImageIsRefused() {
        XCTAssertThrowsError(try store.save(imageData: Data("not a picture".utf8), preferredType: nil))
    }

    func testTheDataDirectoryOverrideIsHonoured() {
        let store = AttachmentStore.default(environment: ["MARMY_DATA_DIR": "/tmp/marmy-attachments-test"])
        XCTAssertEqual(store.directoryURL.path, "/tmp/marmy-attachments-test/pasted-images")
    }
}

/// Typing a path at a prompt.
final class ShellQuotingTests: XCTestCase {

    func testAnOrdinaryPathIsQuoted() {
        XCTAssertEqual(ShellQuoting.quote("/tmp/shot.png"), "'/tmp/shot.png'")
    }

    func testSpacesAndSymbolsSurviveExactly() {
        XCTAssertEqual(
            ShellQuoting.quote("/Users/me/Desktop/Screen Shot $1 `x`.png"),
            "'/Users/me/Desktop/Screen Shot $1 `x`.png'")
    }

    func testASingleQuoteInThePathIsEscaped() {
        XCTAssertEqual(ShellQuoting.quote("/tmp/it's here.png"), "'/tmp/it'\\''s here.png'")
    }

    func testAPathThatCannotBeTypedIsRejected() {
        XCTAssertFalse(ShellQuoting.isTypable("/tmp/line\nbreak.png"))
        XCTAssertFalse(ShellQuoting.isTypable(""))
        XCTAssertTrue(ShellQuoting.isTypable("/tmp/fine.png"))
    }
}
