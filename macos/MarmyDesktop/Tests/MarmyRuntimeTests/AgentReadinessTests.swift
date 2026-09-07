import XCTest
import MarmyCore
@testable import MarmyRuntime

/// Whether Marmy may put a team update into an agent's prompt on its own.
///
/// The screens here are real: captured read-only from the user's own Claude and
/// Codex panes. Nothing was typed into them.
final class AgentReadinessTests: XCTestCase {

    /// A captured frame: `command|cursorX|cursorY|width|height`, then the screen.
    private struct Frame {
        var command: String
        var column: Int
        var row: Int
        var lines: [String]
    }

    private func frame(_ name: String) throws -> Frame {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "Fixtures/\(name)", withExtension: "txt"))
        var lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let header = lines.removeFirst().split(separator: "|").map(String.init)
        return Frame(
            command: header[0], column: Int(header[1])!, row: Int(header[2])!, lines: lines)
    }

    private func escaped(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "Fixtures/\(name)", withExtension: "ansi"))
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
    }

    /// The plain frame, with the cursor's line replaced by a version that
    /// carries its colours — the only line whose colours these tests vary.
    private func assess(
        _ frame: Frame, escapedCursorLine: String, cli: AgentCLI, launchCommand: String? = nil
    ) -> AgentReadiness.Assessment {
        var escaped = frame.lines
        if frame.row < escaped.count { escaped[frame.row] = escapedCursorLine }
        return assess(frame, escapedScreen: escaped, cli: cli, launchCommand: launchCommand)
    }

    private func assess(
        _ frame: Frame, escapedScreen: [String], cli: AgentCLI, launchCommand: String? = nil
    ) -> AgentReadiness.Assessment {
        AgentReadiness.assess(
            cli: cli,
            launchCommand: launchCommand ?? frame.command,
            observedCommand: frame.command,
            screen: frame.lines,
            escapedScreen: escapedScreen,
            cursorRow: frame.row,
            cursorColumn: frame.column,
            acceptsMessages: true)
    }

    // MARK: - The one case that is allowed

    func testARealEmptyCodexPromptIsIdle() throws {
        let frame = try frame("codex-idle")
        let result = assess(frame, escapedCursorLine: try escaped("codex-idle-input"), cli: .codex)

        XCTAssertEqual(result.verdict, .idle, result.reason ?? "")
    }

    func testTheFooterBelowThePromptIsNotHeldAgainstIt() throws {
        // Both CLIs draw a status line under the input; the prompt is still the
        // last thing on screen that matters.
        let frame = try frame("codex-idle")
        XCTAssertTrue(frame.lines.last(where: { !$0.isEmpty })!.contains("gpt-"),
                      "the captured frame really does end with a footer")
        XCTAssertTrue(assess(
            frame, escapedCursorLine: try escaped("codex-idle-input"), cli: .codex).isIdle)
    }

    func testAClaudePromptIsIdleOnceItIsNoLongerWorking() throws {
        // The real busy frame with the working footer replaced by the one Claude
        // draws when it is not: same prompt, same rules above and below it.
        var frame = try frame("claude-busy")
        let footer = try XCTUnwrap(frame.lines.lastIndex { $0.contains("esc to interrupt") })
        frame.lines[footer] =
            "  ⏵⏵ auto mode on (shift+tab to cycle) · ← 2 agents                        /rc"
        frame.lines[frame.row - 3] = ""   // the spinner
        frame.lines[frame.row - 2] = ""   // "1% until auto-compact"

        let result = assess(frame, escapedCursorLine: "❯ ", cli: .claude)
        XCTAssertEqual(result.verdict, .idle, result.reason ?? "")
    }

    func testBothProvidersAtAGenuinelyEmptyPromptAreIdle() {
        // The same shapes as the refusals below, with nothing typed: an empty
        // prompt for Claude, and Codex's faint placeholder for Codex.
        let claude = [
            "Completed response", "", "────────", "❯ ", "  ", "",
            "────────", "  ⏵⏵ auto mode on (shift+tab to cycle)",
        ]
        let claudeResult = AgentReadiness.assess(
            cli: .claude, launchCommand: "2.1.261", observedCommand: "2.1.261",
            screen: claude, escapedScreen: claude, cursorRow: 3, cursorColumn: 2,
            acceptsMessages: true)
        XCTAssertEqual(claudeResult.verdict, .idle, claudeResult.reason ?? "")

        var codex = ["Completed response", "", "› Ask Codex to do anything", "", "", "",
                     "  gpt-example high · /tmp/project"]
        var codexEscaped = codex
        codexEscaped[2] = "\u{1B}[1m›\u{1B}[0m \u{1B}[2mAsk Codex to do anything\u{1B}[0m"
        let codexResult = AgentReadiness.assess(
            cli: .codex, launchCommand: "codex", observedCommand: "codex",
            screen: codex, escapedScreen: codexEscaped, cursorRow: 2, cursorColumn: 2,
            acceptsMessages: true)
        XCTAssertEqual(codexResult.verdict, .idle, codexResult.reason ?? "")

        // And the same Codex prompt with those words actually typed is not.
        codex[2] = "› Ask Codex to do anything"
        codexEscaped[2] = "\u{1B}[1m›\u{1B}[0m Ask Codex to do anything"
        XCTAssertFalse(AgentReadiness.assess(
            cli: .codex, launchCommand: "codex", observedCommand: "codex",
            screen: codex, escapedScreen: codexEscaped, cursorRow: 2, cursorColumn: 2,
            acceptsMessages: true).isIdle)
    }

    func testABlankLineInTheMiddleOfADraftDoesNotEndTheInput() {
        // Blank lines are legal draft content; only the edge of the input area
        // ends the search.
        let screen = ["Completed response", "", "› ", "  ", "  unfinished third line", "",
                      "  gpt-example high · /tmp/project"]
        let result = AgentReadiness.assess(
            cli: .codex, launchCommand: "codex", observedCommand: "codex",
            screen: screen, escapedScreen: screen, cursorRow: 2, cursorColumn: 2,
            acceptsMessages: true)

        XCTAssertFalse(result.isIdle)
        XCTAssertEqual(result.reason, "There is something at this agent's prompt already.")
    }

    func testTheLastLineOfTheScreenIsNotAFooterJustBecauseItIsLast() {
        // A draft on the bottom row, with nothing below it. Reading position as
        // proof of a footer would call this an empty prompt.
        let screen = ["response", "", "› ", "", "  unsent draft"]
        let result = AgentReadiness.assess(
            cli: .codex, launchCommand: "codex", observedCommand: "codex",
            screen: screen, escapedScreen: screen, cursorRow: 2, cursorColumn: 2,
            acceptsMessages: true)

        XCTAssertFalse(result.isIdle, "the last line here is the message, not a footer")
    }

    func testAClaudePromptWithNoClosingRuleIsNotIdle() {
        // The bottom of the box is missing, so Marmy cannot tell where the
        // input ends. An unrecognised layout waits.
        let withFooter = ["response", "", "────────", "❯ ", "",
                          "  ⏵⏵ auto mode on (shift+tab to cycle)"]
        XCTAssertFalse(AgentReadiness.assess(
            cli: .claude, launchCommand: "2.1.261", observedCommand: "2.1.261",
            screen: withFooter, escapedScreen: withFooter, cursorRow: 3, cursorColumn: 2,
            acceptsMessages: true).isIdle)

        // And with nothing at all below it, so there is no text to object to
        // either — only a bottom Marmy cannot find.
        let bare = ["response", "", "────────", "❯ ", "", ""]
        let result = AgentReadiness.assess(
            cli: .claude, launchCommand: "2.1.261", observedCommand: "2.1.261",
            screen: bare, escapedScreen: bare, cursorRow: 3, cursorColumn: 2,
            acceptsMessages: true)
        XCTAssertFalse(result.isIdle)
        XCTAssertEqual(
            result.reason,
            "Marmy cannot see where this agent's prompt ends, so it will not type in it.")
    }

    func testAFooterIsRecognisedByWhatItSaysNotWhereItIs() {
        // Codex's own footer: the bottom line, after a blank, ending in the
        // working directory.
        XCTAssertTrue(AgentReadiness.isFooter(
            AgentReadiness.cells(in: "  gpt-5.6-sol high · ~/work/project"),
            cli: .codex, row: 6, lastNonBlankRow: 6, afterBlank: true))
        XCTAssertFalse(AgentReadiness.isFooter(
            AgentReadiness.cells(in: "  see foo · bar"),
            cli: .codex, row: 6, lastNonBlankRow: 6, afterBlank: true),
            "a middle dot alone is not a footer")
        XCTAssertFalse(AgentReadiness.isFooter(
            AgentReadiness.cells(in: "  gpt-5.6-sol high · ~/work/project"),
            cli: .codex, row: 4, lastNonBlankRow: 6, afterBlank: true),
            "and neither is one in the middle of the screen")
        XCTAssertFalse(AgentReadiness.isFooter(
            AgentReadiness.cells(in: "  gpt-5.6-sol high · ~/work/project"),
            cli: .claude, row: 6, lastNonBlankRow: 6, afterBlank: true),
            "Claude closes its input with a rule; it has no footer of this kind")
    }

    // MARK: - Refusals

    func testAnAgentWithSomethingTypedAtItsPromptIsNotIdle() throws {
        // `› test`, waiting to be sent. Marmy must not append to it or send it.
        let frame = try frame("codex-draft")
        let result = assess(
            frame, escapedCursorLine: "\u{1B}[1m›\u{1B}[0m test", cli: .codex)

        XCTAssertFalse(result.isIdle)
        XCTAssertEqual(result.reason, "There is something at this agent's prompt already.")
    }

    func testABusyAgentWithAnEmptyPromptIsNotIdle() throws {
        // Claude's input line is empty while it works; the footer says otherwise.
        let frame = try frame("claude-busy")
        XCTAssertEqual(frame.lines[frame.row].trimmingCharacters(in: .whitespaces), "❯",
                       "the prompt really is empty in this frame")
        let result = assess(frame, escapedCursorLine: "❯ ", cli: .claude)

        XCTAssertFalse(result.isIdle, "an empty prompt is not proof of an idle agent")
        XCTAssertEqual(result.reason, "This agent is busy or waiting for an answer.")
    }

    func testADraftWithTheCursorMovedBackToTheStartIsNotIdle() throws {
        // Cursor at Home, `test` still there: the column alone would say yes.
        var frame = try frame("codex-draft")
        frame.column = 2
        let result = assess(frame, escapedCursorLine: "\u{1B}[1m›\u{1B}[0m test", cli: .codex)

        XCTAssertFalse(result.isIdle)
    }

    func testAPlaceholderIsToldFromADraftByItsColour() throws {
        // The same characters, faint or not, are a placeholder or a message.
        let frame = try frame("codex-idle")
        let typed = "\u{1B}[1m›\u{1B}[0m Ask Codex to do anything"
        XCTAssertFalse(assess(frame, escapedCursorLine: typed, cli: .codex).isIdle,
                       "the same words typed by hand are a draft")
        XCTAssertTrue(assess(
            frame, escapedCursorLine: try escaped("codex-idle-input"), cli: .codex).isIdle)
    }

    func testAMultilineDraftIsNotIdleEvenWithTheCursorOnAnEmptyLine() throws {
        // A message half-typed over two lines, the cursor on the second.
        var frame = try frame("codex-idle")
        frame.lines[frame.row - 1] = "› first line of something"

        let result = assess(frame, escapedCursorLine: "  ", cli: .codex)
        XCTAssertFalse(result.isIdle, "there is no prompt on the cursor's line at all")
    }

    func testACodexDraftBelowAnEmptyFirstLineIsNotIdle() throws {
        // Two lines typed, the cursor back on the empty first one. The line the
        // cursor is on says nothing is there; the line below it disagrees.
        var frame = try frame("codex-idle")
        frame.column = 2
        frame.lines[frame.row] = "› "
        frame.lines[frame.row + 1] = "  and the rest of what was typed"

        var escaped = frame.lines
        escaped[frame.row] = "\u{1B}[1m›\u{1B}[0m "

        let result = assess(frame, escapedScreen: escaped, cli: .codex)
        XCTAssertFalse(result.isIdle, "a message half-typed over two lines is not an empty prompt")
        XCTAssertEqual(result.reason, "There is something at this agent's prompt already.")
    }

    func testAClaudeDraftBelowAnEmptyFirstLineIsNotIdle() throws {
        var frame = try frame("claude-busy")
        let footer = try XCTUnwrap(frame.lines.lastIndex { $0.contains("esc to interrupt") })
        frame.lines[footer] = "  ⏵⏵ auto mode on (shift+tab to cycle) · ← 2 agents"
        frame.lines[frame.row - 3] = ""
        frame.lines[frame.row - 2] = ""
        frame.lines[frame.row + 1] = "  the second line of the message"

        let result = assess(frame, escapedCursorLine: "❯ ", cli: .claude)
        XCTAssertFalse(result.isIdle)
        XCTAssertEqual(result.reason, "There is something at this agent's prompt already.")
    }

    func testTheFooterUnderTheRealIdlePromptIsStillAllowed() throws {
        // The same walk downwards, on the frames that really are idle.
        let codex = try frame("codex-idle")
        XCTAssertTrue(assess(
            codex, escapedCursorLine: try escaped("codex-idle-input"), cli: .codex).isIdle)

        var claude = try frame("claude-busy")
        let footer = try XCTUnwrap(claude.lines.lastIndex { $0.contains("esc to interrupt") })
        claude.lines[footer] = "  ⏵⏵ auto mode on (shift+tab to cycle) · ← 2 agents"
        claude.lines[claude.row - 3] = ""
        claude.lines[claude.row - 2] = ""
        XCTAssertTrue(assess(claude, escapedCursorLine: "❯ ", cli: .claude).isIdle,
                      "the rule and the footer below the prompt are not a draft")
    }

    func testAPermissionMenuIsNotIdle() throws {
        var frame = try frame("codex-idle")
        frame.lines[frame.row - 3] = "❯ 1. Yes, allow this"
        frame.lines[frame.row - 2] = "  2. No, tell Codex what to do differently"

        let result = assess(frame, escapedCursorLine: try escaped("codex-idle-input"), cli: .codex)
        XCTAssertFalse(result.isIdle)
        XCTAssertEqual(result.reason, "This agent is showing a menu to choose from.")
    }

    func testOldConversationTextIsNotMistakenForBusyness() throws {
        // Someone quoted the footer twenty lines up. That is history.
        var frame = try frame("codex-idle")
        frame.lines[2] = "  I told it to press esc to interrupt and it did"

        XCTAssertTrue(assess(
            frame, escapedCursorLine: try escaped("codex-idle-input"), cli: .codex).isIdle)
    }

    func testAShellIsNeverIdleEnough() throws {
        var frame = try frame("codex-idle")
        frame.command = "zsh"
        frame.lines[frame.row] = "$ "

        let result = assess(frame, escapedCursorLine: "$ ", cli: .codex, launchCommand: "zsh")
        XCTAssertFalse(result.isIdle)
    }

    func testADifferentProgramInThePaneIsNotIdle() throws {
        let frame = try frame("codex-idle")
        let result = assess(
            frame, escapedCursorLine: try escaped("codex-idle-input"), cli: .codex,
            launchCommand: "claude")

        XCTAssertFalse(result.isIdle)
        XCTAssertEqual(result.reason,
                       "The program in this pane is \"codex\" now, not the \"claude\" Marmy started.")
    }

    func testATerminalNodeIsNeverWrittenTo() throws {
        let frame = try frame("codex-idle")
        let result = AgentReadiness.assess(
            cli: .terminal, launchCommand: "bash", observedCommand: "bash",
            screen: frame.lines, escapedScreen: frame.lines, cursorRow: frame.row,
            cursorColumn: 2, acceptsMessages: false)

        XCTAssertFalse(result.isIdle)
    }

    func testAnUnrecognisedPromptIsNotIdle() throws {
        var frame = try frame("codex-idle")
        frame.lines[frame.row] = "  loading…"

        XCTAssertFalse(assess(frame, escapedCursorLine: "  loading…", cli: .codex).isIdle)
    }

    // MARK: - Reading colours

    func testFaintTextIsRecognisedThroughColourChanges() {
        let line = "\u{1B}[48;2;30;30;30m \u{1B}[2mplaceholder\u{1B}[0m"
        let cells = AgentReadiness.cells(in: line)

        XCTAssertEqual(String(cells.map(\.character)), " placeholder")
        XCTAssertTrue(cells.dropFirst().allSatisfy(\.isFaint))
        XCTAssertEqual(cells.last?.column, 11)
    }
}
