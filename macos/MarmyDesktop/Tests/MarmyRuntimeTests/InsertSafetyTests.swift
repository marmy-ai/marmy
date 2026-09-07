import XCTest
@testable import MarmyRuntime

/// What Marmy is allowed to type into a prompt on its own.
final class InsertSafetyTests: XCTestCase {

    func testOneOrdinaryLineIsFine() {
        XCTAssertNil(InsertSafety.refusal(for: "please check the build and report back"))
        XCTAssertNil(InsertSafety.refusal(for: "'/Users/me/Desktop/Screen Shot.png'"))

    }

    func testMoreThanOneLineIsRefused() {
        // A pasted newline runs the line before it in anything that has not
        // turned bracketed paste on, and tmux cannot tell us whether it has.
        XCTAssertEqual(InsertSafety.refusal(for: "first line\nsecond line"), .multipleLines)
        XCTAssertEqual(InsertSafety.refusal(for: "trailing newline\n"), .multipleLines)
        XCTAssertEqual(InsertSafety.refusal(for: "carriage\rreturn"), .multipleLines)
    }

    func testControlCharactersAreRefused() {
        XCTAssertEqual(InsertSafety.refusal(for: "bell\u{7}"), .controlCharacters)
        XCTAssertEqual(InsertSafety.refusal(for: "with a\ttab"), .controlCharacters,
                       "Tab is completion or a change of focus in a terminal, not a character.")
        XCTAssertEqual(InsertSafety.refusal(for: "escape\u{1B}[201~and more"), .controlCharacters,
                       "a paste terminator would let the rest be read as keystrokes")
        XCTAssertEqual(InsertSafety.refusal(for: "null\u{0}byte"), .controlCharacters)
    }

    func testNothingIsNothing() {
        XCTAssertEqual(InsertSafety.refusal(for: ""), .empty)
    }

    func testTheRefusalSaysWhatHappenedToTheText() {
        let refusal = try? XCTUnwrap(InsertSafety.refusal(for: "two\nlines"))
        XCTAssertTrue(refusal?.description.contains("the text is kept") ?? false)
    }
}
