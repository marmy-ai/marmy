import AppKit
import XCTest
@testable import MarmyUI

/// The history view shows agent output. Nothing in that output may do anything
/// except colour text.
final class ANSITextTests: XCTestCase {

    private func plainText(_ source: String) -> String {
        ANSIText.runs(from: source).map(\.text).joined()
    }

    func testPlainTextIsUntouched() {
        XCTAssertEqual(plainText("hello world\nsecond line"), "hello world\nsecond line")
    }

    func testColoursSplitTheTextIntoStyledRuns() {
        let runs = ANSIText.runs(from: "normal \u{1B}[31mred\u{1B}[0m done")
        XCTAssertEqual(runs.map(\.text), ["normal ", "red", " done"])
        XCTAssertEqual(runs[1].style.foreground, ANSIText.basic(1, bright: false))
        XCTAssertNil(runs[2].style.foreground, "reset clears the colour")
    }

    func testEmphasisAndItsReset() {
        let runs = ANSIText.runs(from: "\u{1B}[1;4mloud\u{1B}[22;24m quiet")
        XCTAssertTrue(runs[0].style.bold)
        XCTAssertTrue(runs[0].style.underline)
        XCTAssertFalse(runs[1].style.bold)
        XCTAssertFalse(runs[1].style.underline)
    }

    func test256ColourAndTrueColour() {
        let indexed = ANSIText.runs(from: "\u{1B}[38;5;196mx")
        XCTAssertEqual(indexed[0].style.foreground, ANSIText.palette256(196))

        let truecolor = ANSIText.runs(from: "\u{1B}[48;2;10;20;30my")
        XCTAssertEqual(
            truecolor[0].style.background,
            NSColor(srgbRed: 10.0 / 255, green: 20.0 / 255, blue: 30.0 / 255, alpha: 1))
    }

    func testBrightColoursAndDefaults() {
        let runs = ANSIText.runs(from: "\u{1B}[91mbright\u{1B}[39mdefault")
        XCTAssertEqual(runs[0].style.foreground, ANSIText.basic(1, bright: true))
        XCTAssertNil(runs[1].style.foreground)
    }

    func testCursorMovesAndErasesAreDroppedNotDrawn() {
        // A transcript is full of these; none of them may reach the screen.
        XCTAssertEqual(plainText("a\u{1B}[2J\u{1B}[Hb\u{1B}[3Ac"), "abc")
        XCTAssertEqual(plainText("x\u{1B}[?25ly"), "xy")
    }

    func testOSCSequencesAreSwallowedIncludingClipboardWrites() {
        // OSC 52 is a clipboard write. Showing history must never perform one.
        let source = "before\u{1B}]52;c;aGVsbG8=\u{7}after"
        XCTAssertEqual(plainText(source), "beforeafter")

        let stTerminated = "one\u{1B}]0;window title\u{1B}\\two"
        XCTAssertEqual(plainText(stTerminated), "onetwo")
    }

    func testDeviceControlStringsAreSwallowed() {
        XCTAssertEqual(plainText("a\u{1B}Psome;payload\u{1B}\\b"), "ab")
    }

    func testAnUnterminatedEscapeDoesNotEatTheRest() {
        XCTAssertEqual(plainText("visible\u{1B}"), "visible")
        XCTAssertEqual(plainText("visible\u{1B}[31"), "visible")
    }

    func testCarriageReturnsAreDropped() {
        XCTAssertEqual(plainText("line\r\nnext"), "line\nnext")
    }

    func testAttributedStringUsesTheDefaultColourForUnstyledText() {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let attributed = ANSIText.attributedString(
            from: "plain \u{1B}[31mred", font: font, defaultColor: .labelColor)

        XCTAssertEqual(attributed.string, "plain red")
        var range = NSRange()
        let first = attributed.attribute(.foregroundColor, at: 0, effectiveRange: &range) as? NSColor
        XCTAssertEqual(first, NSColor.labelColor)
        let coloured = attributed.attribute(.foregroundColor, at: 6, effectiveRange: &range) as? NSColor
        XCTAssertEqual(coloured, ANSIText.basic(1, bright: false))
    }

    func testInverseSwapsForegroundAndBackground() {
        let runs = ANSIText.runs(from: "\u{1B}[7minverted")
        XCTAssertTrue(runs[0].style.inverse)
    }

    func testALongTranscriptStaysReadable() {
        // Roughly what a coding agent emits: colours, cursor moves, and text.
        let line = "\u{1B}[2m12:03\u{1B}[0m \u{1B}[32m✓\u{1B}[0m built \u{1B}[1mtarget\u{1B}[0m\n"
        let source = String(repeating: line, count: 500)
        let text = plainText(source)

        XCTAssertEqual(text.components(separatedBy: "\n").count - 1, 500)
        XCTAssertFalse(text.contains("\u{1B}"))
        XCTAssertTrue(text.contains("✓"))
    }
}
