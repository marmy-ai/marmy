import XCTest
import MarmyCore
import MarmyRuntime
final class ParentReadinessProbeTests: XCTestCase {
    func testBlankLinesDoNotHideDraft() {
        let cases: [(AgentCLI, String, [String], Int)] = [
            (.claude, "2.1.261", ["Completed response", "", "────────", "❯ ", "  ", "  unfinished third line", "────────", "  ⏵⏵ auto mode on (shift+tab to cycle)"], 3),
            (.codex, "codex", ["Completed response", "", "› ", "  ", "  unfinished third line", "", "  gpt-example high · /tmp/project"], 2)
        ]
        for (cli, command, screen, row) in cases {
            let result = AgentReadiness.assess(cli: cli, launchCommand: command, observedCommand: command, screen: screen, escapedScreen: screen, cursorRow: row, cursorColumn: 2, acceptsMessages: true)
            XCTAssertFalse(result.isIdle, "\(cli) unfinished multiline input")
        }
    }
}
