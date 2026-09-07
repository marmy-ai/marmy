import XCTest
@testable import MarmyCore

final class TmuxNameTests: XCTestCase {

    func testAcceptsPlainNames() {
        XCTAssertTrue(TmuxName.isValid("lead"))
        XCTAssertTrue(TmuxName.isValid("build-2"))
        XCTAssertTrue(TmuxName.isValid("worker_opus"))
        XCTAssertTrue(TmuxName.isValid("2nd-shift"))
    }

    func testRejectsNamesTmuxCannotTarget() {
        XCTAssertEqual(TmuxName.problem(with: ""), .empty)
        XCTAssertEqual(TmuxName.problem(with: "-lead"), .leadingCharacter)
        XCTAssertEqual(TmuxName.problem(with: String(repeating: "a", count: 65)), .tooLong(limit: 64))

        guard case .invalidCharacters = TmuxName.problem(with: "my session") else {
            return XCTFail("spaces must be rejected")
        }
        guard case .invalidCharacters = TmuxName.problem(with: "lead:0") else {
            return XCTFail("colon must be rejected")
        }
        guard case .invalidCharacters = TmuxName.problem(with: "lead.1") else {
            return XCTFail("dot must be rejected")
        }
    }

    func testSanitizeProducesValidNames() {
        XCTAssertEqual(TmuxName.sanitize("My Session"), "My-Session")
        XCTAssertEqual(TmuxName.sanitize("lead:0"), "lead-0")
        XCTAssertEqual(TmuxName.sanitize("  --  "), "agent")
        XCTAssertEqual(TmuxName.sanitize(""), "agent")
        XCTAssertTrue(TmuxName.isValid(TmuxName.sanitize(String(repeating: "x", count: 200))))
        XCTAssertTrue(TmuxName.isValid(TmuxName.sanitize("💥 crash 💥")))
    }
}
