import XCTest
@testable import MarmyCore

final class PromptTemplateSyntaxTests: XCTestCase {

    private let context = PromptRenderContext([
        "agent.name": "Build",
        "manager.name": "",
        "contacts": "Verify (verify)",
    ])

    func testSubstitutesVariablesAndIgnoresTagWhitespace() throws {
        XCTAssertEqual(
            try PromptTemplateSyntax.render("Hi {{ agent.name }}.", context: context),
            "Hi Build.")
    }

    func testSectionRendersOnlyWhenValueIsPresent() throws {
        let template = "{{#contacts}}Talk to {{contacts}}.{{/contacts}}{{#manager.name}}Boss{{/manager.name}}"
        XCTAssertEqual(try PromptTemplateSyntax.render(template, context: context), "Talk to Verify (verify).")
    }

    func testInvertedSectionRendersOnlyWhenValueIsBlank() throws {
        let template = "{{^manager.name}}No manager.{{/manager.name}}{{^contacts}}No contacts.{{/contacts}}"
        XCTAssertEqual(try PromptTemplateSyntax.render(template, context: context), "No manager.")
    }

    func testBlankValueCountsAsAbsent() throws {
        let blank = PromptRenderContext(["x": "   \n "])
        XCTAssertEqual(try PromptTemplateSyntax.render("{{#x}}yes{{/x}}{{^x}}no{{/x}}", context: blank), "no")
    }

    func testStandaloneSectionTagsDoNotLeaveBlankLines() throws {
        let template = """
        A
        {{#contacts}}
        B
        {{/contacts}}
        C
        """
        XCTAssertEqual(try PromptTemplateSyntax.render(template, context: context), "A\nB\nC")

        let hidden = """
        A
        {{#manager.name}}
        B
        {{/manager.name}}
        C
        """
        XCTAssertEqual(try PromptTemplateSyntax.render(hidden, context: context), "A\nC")
    }

    func testInlineSectionAfterAVariableKeepsItsNewlines() throws {
        // Regression: the pending literal is flushed when a variable is emitted,
        // so an inline section tag used to look like the start of a line and
        // swallowed the newline that opened its body.
        let named = PromptRenderContext(["agent.name": "Build", "manager.name": "Lead"])
        XCTAssertEqual(
            try PromptTemplateSyntax.render(
                "a{{agent.name}}{{#manager.name}}\nx\n{{/manager.name}}", context: named),
            "aBuild\nx\n")
    }

    func testTagAfterAVariableOnTheSameLineIsNotStandalone() throws {
        let named = PromptRenderContext(["agent.name": "Build", "manager.name": "Lead"])
        XCTAssertEqual(
            try PromptTemplateSyntax.render(
                "{{agent.name}} {{#manager.name}}\nreports to {{manager.name}}{{/manager.name}}",
                context: named),
            "Build \nreports to Lead")
    }

    func testStandaloneDetectionStillWorksAfterAVariableOnTheLineBefore() throws {
        let named = PromptRenderContext(["agent.name": "Build", "manager.name": "Lead"])
        let template = "{{agent.name}}\n  {{#manager.name}}\nx\n{{/manager.name}}\ndone"
        XCTAssertEqual(try PromptTemplateSyntax.render(template, context: named), "Build\nx\ndone")
    }

    func testInlineSectionTagsKeepSurroundingText() throws {
        XCTAssertEqual(
            try PromptTemplateSyntax.render("x {{#contacts}}y{{/contacts}} z", context: context),
            "x y z")
    }

    func testRenderingIsDeterministic() throws {
        let template = "{{agent.name}} {{#contacts}}{{contacts}}{{/contacts}}"
        let once = try PromptTemplateSyntax.render(template, context: context)
        for _ in 0..<5 {
            XCTAssertEqual(try PromptTemplateSyntax.render(template, context: context), once)
        }
    }

    func testUnknownVariableThrows() {
        XCTAssertThrowsError(try PromptTemplateSyntax.render("{{agent.nope}}", context: context)) { error in
            XCTAssertEqual(error as? PromptTemplateError, .unknownVariable("agent.nope", line: 1))
        }
    }

    func testUnknownSectionNameThrows() {
        XCTAssertThrowsError(try PromptTemplateSyntax.render("{{#nope}}x{{/nope}}", context: context)) { error in
            XCTAssertEqual(error as? PromptTemplateError, .unknownVariable("nope", line: 1))
        }
    }

    func testMalformedSyntaxIsReportedWithItsLine() {
        func error(_ source: String) -> PromptTemplateError? {
            do {
                _ = try PromptTemplateSyntax.render(source, context: context)
                return nil
            } catch {
                return error as? PromptTemplateError
            }
        }

        XCTAssertEqual(error("ok\n{{agent.name"), .unterminatedTag(line: 2))
        XCTAssertEqual(error("{{}}"), .emptyTag(line: 1))
        XCTAssertEqual(error("{{2bad}}"), .invalidIdentifier("2bad", line: 1))
        XCTAssertEqual(error("{{#agent.name}}x"), .unclosedSection("agent.name", line: 1))
        XCTAssertEqual(error("{{/agent.name}}"), .unexpectedSectionEnd("agent.name", line: 1))
        XCTAssertEqual(
            error("{{#agent.name}}x{{/contacts}}"),
            .mismatchedSectionEnd(expected: "agent.name", found: "contacts", line: 1))
    }

    func testReferencedVariablesInFirstUseOrder() throws {
        let names = try PromptTemplateSyntax.referencedVariables(
            in: "{{agent.name}} {{#contacts}}{{contacts}}{{/contacts}} {{agent.name}}")
        XCTAssertEqual(names, ["agent.name", "contacts"])
    }

    func testValidateAgainstKnownVariables() {
        XCTAssertNoThrow(try PromptTemplateSyntax.validate(
            "{{agent.name}}", knownVariables: PromptVariables.allKeySet))
        XCTAssertThrowsError(try PromptTemplateSyntax.validate(
            "{{agent.hostname}}", knownVariables: PromptVariables.allKeySet))
    }

    func testIdentifierRules() {
        XCTAssertTrue(PromptTemplateSyntax.isValidIdentifier("agent.name"))
        XCTAssertTrue(PromptTemplateSyntax.isValidIdentifier("reports_list"))
        XCTAssertFalse(PromptTemplateSyntax.isValidIdentifier("agent..name"))
        XCTAssertFalse(PromptTemplateSyntax.isValidIdentifier(".name"))
        XCTAssertFalse(PromptTemplateSyntax.isValidIdentifier("agent name"))
    }
}
