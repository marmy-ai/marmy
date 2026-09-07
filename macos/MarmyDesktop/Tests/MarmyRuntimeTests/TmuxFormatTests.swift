import XCTest
@testable import MarmyRuntime

final class TmuxFormatTests: XCTestCase {

    func testFormatStringIsLengthPrefixed() {
        XCTAssertEqual(
            TmuxFormat.lengthPrefixed(["session_id", "session_name"]),
            "#{n:session_id}:#{session_id}#{n:session_name}:#{session_name}")
    }

    func testParsesValuesContainingNewlinesAndSeparatorBytes() throws {
        // A working directory really can contain a newline or a 0x1F, which is
        // why nothing is delimited by value.
        let path = "/tmp/we\u{1F}ird\ndir"
        let data = Data(TmuxFixtures.output([["%0", "$0", path], ["%1", "$0", "/tmp"]]).utf8)

        let records = try TmuxFormat.parseRecords(data, fieldCount: 3, command: "list-panes")
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0][2], path)
        XCTAssertEqual(records[1][2], "/tmp")
    }

    func testParsesMultibyteValuesByByteLength() throws {
        let name = "é🐈 e\u{301}"
        let data = Data(TmuxFixtures.output([["$0", name]]).utf8)
        let records = try TmuxFormat.parseRecords(data, fieldCount: 2, command: "list-sessions")
        XCTAssertEqual(records[0][1], name)
    }

    func testEmptyOutputIsNoRecords() throws {
        XCTAssertTrue(try TmuxFormat.parseRecords(Data(), fieldCount: 3, command: "list-panes").isEmpty)
        XCTAssertTrue(try TmuxFormat.parseRecords(Data("\n".utf8), fieldCount: 3, command: "list-panes").isEmpty)
    }

    func testTruncatedRecordThrowsRatherThanDroppingARow() {
        // A dropped row would hide a running agent, so this has to be an error.
        let data = Data("2:%05:$0".utf8)
        XCTAssertThrowsError(try TmuxFormat.parseRecords(data, fieldCount: 2, command: "list-panes"))
    }

    func testMissingLengthPrefixThrows() {
        XCTAssertThrowsError(try TmuxFormat.parseRecords(Data("%0\n".utf8), fieldCount: 1, command: "list-panes"))
    }

    func testJunkBetweenRecordsThrows() {
        let data = Data("2:%0x2:%1\n".utf8)
        XCTAssertThrowsError(try TmuxFormat.parseRecords(data, fieldCount: 1, command: "list-panes"))
    }

    func testParseRecordRequiresExactlyOne() throws {
        let two = Data(TmuxFixtures.output([["a"], ["b"]]).utf8)
        XCTAssertThrowsError(try TmuxFormat.parseRecord(two, fieldCount: 1, command: "display-message"))
        XCTAssertEqual(try TmuxFormat.parseRecord(Data(TmuxFixtures.record(["a"]).utf8), fieldCount: 1, command: "x"), ["a"])
    }

    func testNonNumericFieldThrows() {
        XCTAssertThrowsError(try TmuxFormat.integer("later", command: "list-sessions"))
        XCTAssertEqual(try TmuxFormat.integer("42", command: "list-sessions"), 42)
    }

    func testTargetSyntax() {
        XCTAssertEqual(TmuxTarget.session(name: "lead"), "=lead")
        XCTAssertEqual(TmuxTarget.pane(inSessionNamed: "lead"), "=lead:")
    }
}
