import Foundation
import MarmyCore

/// Whether it is safe to submit something to an agent without being asked.
///
/// Marmy sends an automatic message — a team update — only when it can
/// positively establish that the agent is sitting at an empty prompt with
/// nothing going on. The checks come from what these CLIs actually put on
/// screen, which is less obliging than it sounds:
///
/// - Both draw a footer *below* the input line, so "the cursor is on the last
///   line" tests nothing.
/// - Claude's input line is empty while it is working. An empty input line is
///   necessary and nowhere near sufficient; the work is announced around it.
/// - Codex fills its empty input with a faint "Ask Codex to do anything". In
///   plain text that is indistinguishable from a half-typed message, so the
///   input is read with its colours on: a placeholder is faint, and what
///   somebody typed is not.
/// - A message typed over several lines leaves the cursor on the first of them,
///   which can be blank while the rest of the message sits below it — and so can
///   the lines between. So the whole input area is read, down to the edge that
///   ends it (Claude's rule, or the footer line at the bottom of the screen),
///   never just the line the cursor is on and never stopping at a blank.
///
/// So: the program must be the one Marmy started and not a shell; nothing in
/// the region around the prompt may say work is under way or a question is
/// waiting; the cursor must be at the CLI's own input line; and that line must
/// hold nothing but its placeholder. Anything unrecognised is "not now" — a
/// screen is never taken as permission by itself.
public enum AgentReadiness {

    public struct Assessment: Equatable, Sendable {
        public enum Verdict: Equatable, Sendable {
            case idle
            case notIdle(String)
        }

        public var verdict: Verdict
        public var observedCommand: String
        public var cursorLine: String

        public var isIdle: Bool { verdict == .idle }

        public var reason: String? {
            if case .notIdle(let reason) = verdict { return reason }
            return nil
        }
    }

    /// What a program in a pane must not be for an automatic message to go: a
    /// shell, or Marmy's own launcher caught before the CLI replaced it.
    public static let disqualifyingCommands: Set<String> = [
        "sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "screen", "tmux",
        "marmy-agent-launch", "MarmyDesktop", "login", "env", "ssh",
    ]

    /// Decoration a CLI draws around its input line.
    static let boxCharacters: Set<Character> = ["│", "|", "┃", "▏", "▕", "║", "╎", "─", "═"]

    /// The character a CLI puts in front of what you are about to type. Shell
    /// prompt characters are deliberately absent: `$`, `#` and `%` mean a shell,
    /// and Marmy does not type in shells.
    static func promptGlyphs(for cli: AgentCLI) -> Set<Character> {
        switch cli {
        case .claude: return [">", "❯"]
        case .codex: return ["›", "⏵", ">", "❯"]
        case .terminal: return []
        }
    }

    /// What these CLIs say while they are working, or while they are waiting for
    /// an answer that is not a message.
    static let busyMarkers: [String] = [
        "esc to interrupt",
        "ctrl+c to interrupt",
        "press enter to continue",
        "do you want to",
        "(y/n)",
        "[y/n]",
        "waiting for your response",
    ]

    /// How far above the input line to read for those. Both CLIs draw their
    /// status and their questions immediately above the prompt; the
    /// conversation further up is history, and quoting "esc to interrupt" in it
    /// should not stop Marmy forever.
    static let markerRowsAbovePrompt = 8

    public static func assess(
        cli: AgentCLI?,
        launchCommand: String?,
        observedCommand: String,
        screen: [String],
        escapedScreen: [String],
        cursorRow: Int,
        cursorColumn: Int,
        acceptsMessages: Bool
    ) -> Assessment {
        let cursorLine = (cursorRow >= 0 && cursorRow < screen.count) ? screen[cursorRow] : ""

        func result(_ verdict: Assessment.Verdict) -> Assessment {
            Assessment(verdict: verdict, observedCommand: observedCommand, cursorLine: cursorLine)
        }

        guard acceptsMessages, let cli, cli.isAutonomousAgent else {
            return result(.notIdle("This is a terminal you drive yourself; Marmy does not type in it."))
        }
        guard let launchCommand, !launchCommand.isEmpty else {
            return result(.notIdle(
                "Marmy did not start this session, so it cannot tell what is running in it."))
        }
        guard !disqualifyingCommands.contains(launchCommand) else {
            return result(.notIdle(
                "Marmy could not establish which program this agent is running, so it will not type in it."))
        }
        guard observedCommand == launchCommand else {
            return result(.notIdle(
                "The program in this pane is \u{22}\(observedCommand)\u{22} now, not the "
                    + "\u{22}\(launchCommand)\u{22} Marmy started."))
        }
        guard cursorRow >= 0, cursorRow < screen.count else {
            return result(.notIdle("Marmy cannot see where this agent's cursor is."))
        }

        let region = screen[max(0, cursorRow - markerRowsAbovePrompt)...].joined(separator: "\n")
            .lowercased()
        for marker in busyMarkers where region.contains(marker) {
            return result(.notIdle("This agent is busy or waiting for an answer."))
        }
        if screen[max(0, cursorRow - markerRowsAbovePrompt)...].contains(where: isMenuLine) {
            return result(.notIdle("This agent is showing a menu to choose from."))
        }

        // The input area, read with its colours, so a placeholder can be told
        // from something half-typed.
        let escapedCursorLine = cursorRow < escapedScreen.count ? escapedScreen[cursorRow] : ""
        let promptCells = cells(in: escapedCursorLine)
        guard let glyph = promptCells.first(where: { !$0.character.isWhitespace }),
              promptGlyphs(for: cli).contains(glyph.character)
        else {
            return result(.notIdle("Marmy does not recognise this agent's prompt, so it will not type."))
        }
        let afterGlyph = promptCells.drop { $0.column <= glyph.column }
        if afterGlyph.contains(where: { !$0.character.isWhitespace && !$0.isFaint }) {
            return result(.notIdle("There is something at this agent's prompt already."))
        }
        guard cursorColumn > glyph.column, cursorColumn <= glyph.column + 2 else {
            return result(.notIdle("This agent's cursor is not at the start of its prompt."))
        }
        // The rest of the input area. A message typed over several lines leaves
        // the cursor on an empty first line with the message below it, and that
        // is not an empty prompt. A blank line in the middle of it is part of
        // the message, so only the edge of the input area ends the search — and
        // that edge has to be recognised for what it is, not assumed from where
        // it sits. A line is the end of the input when it is the rule that
        // closes the box, or the provider's own footer. If neither turns up, the
        // layout is not one Marmy knows, and not knowing is not permission.
        let lastNonBlankRow = escapedScreen.lastIndex {
            !cells(in: $0).allSatisfy { $0.character.isWhitespace }
        }
        var row = cursorRow + 1
        var afterBlank = false
        var foundEdge = false
        while row < escapedScreen.count {
            let lineCells = cells(in: escapedScreen[row])
            let visible = lineCells.filter { !$0.character.isWhitespace }
            if visible.isEmpty {
                afterBlank = true
                row += 1
                continue
            }
            if visible.allSatisfy({ boxCharacters.contains($0.character) }) {
                foundEdge = true
                break
            }
            if isFooter(
                lineCells, cli: cli, row: row, lastNonBlankRow: lastNonBlankRow,
                afterBlank: afterBlank) {
                foundEdge = true
                break
            }
            if visible.contains(where: { !$0.isFaint }) {
                return result(.notIdle("There is something at this agent's prompt already."))
            }
            afterBlank = false
            row += 1
        }
        guard foundEdge else {
            return result(.notIdle(
                "Marmy cannot see where this agent's prompt ends, so it will not type in it."))
        }
        return result(.idle)
    }

    // MARK: - Reading a line with its colours

    struct Cell: Equatable {
        var character: Character
        var column: Int
        /// Drawn faint (SGR 2) — how both CLIs draw a placeholder.
        var isFaint: Bool
    }

    /// The printable cells of a line captured with escape sequences, each with
    /// whether it was drawn faint. Sequences that are not SGR are skipped;
    /// nothing else on the line matters here.
    static func cells(in escaped: String) -> [Cell] {
        var cells: [Cell] = []
        var faint = false
        var column = 0
        var iterator = Array(escaped)
        var index = 0
        while index < iterator.count {
            let character = iterator[index]
            if character == "\u{1B}" {
                index += 1
                guard index < iterator.count else { break }
                if iterator[index] == "[" {
                    index += 1
                    var parameters = ""
                    while index < iterator.count, !("@"..."~").contains(iterator[index]) {
                        parameters.append(iterator[index])
                        index += 1
                    }
                    let final = index < iterator.count ? iterator[index] : " "
                    index += 1
                    if final == "m" { faint = applySGR(parameters, to: faint) }
                } else if iterator[index] == "]" {
                    // An OS command, ended by BEL or ST.
                    while index < iterator.count, iterator[index] != "\u{07}" {
                        if iterator[index] == "\u{1B}", index + 1 < iterator.count,
                           iterator[index + 1] == "\\" {
                            index += 1
                            break
                        }
                        index += 1
                    }
                    index += 1
                } else {
                    index += 1
                }
                continue
            }
            if character.unicodeScalars.first.map({ $0.value < 0x20 }) == true {
                index += 1
                continue
            }
            cells.append(Cell(character: character, column: column, isFaint: faint))
            column += 1
            index += 1
        }
        return cells
    }

    static func applySGR(_ parameters: String, to faint: Bool) -> Bool {
        var faint = faint
        let codes = parameters.split(separator: ";", omittingEmptySubsequences: false)
        if codes.isEmpty { return false }  // A bare ESC[m is a reset.
        var index = 0
        while index < codes.count {
            let code = Int(codes[index]) ?? 0
            switch code {
            case 0: faint = false
            case 2: faint = true
            case 22: faint = false
            case 38, 48:
                // A colour, whose parameters are not attributes.
                if index + 1 < codes.count, Int(codes[index + 1]) == 5 {
                    index += 2
                } else if index + 1 < codes.count, Int(codes[index + 1]) == 2 {
                    index += 4
                }
            default: break
            }
            index += 1
        }
        return faint
    }

    /// Whether a line is the provider's own status footer, rather than the last
    /// thing somebody typed.
    ///
    /// Claude closes its input with a rule, so it needs no footer rule of its
    /// own here. Codex does not: its footer is the bottom line of the screen,
    /// separated from the input by a blank line, and it ends with the working
    /// directory after a middle dot — `gpt-5.6-sol high · ~/work/project`.
    /// Position alone proves nothing: the last line of a screen can just as
    /// easily be the last line of a half-typed message.
    static func isFooter(
        _ cells: [Cell],
        cli: AgentCLI,
        row: Int,
        lastNonBlankRow: Int?,
        afterBlank: Bool
    ) -> Bool {
        guard cli == .codex, row == lastNonBlankRow, afterBlank else { return false }
        let text = String(cells.map(\.character))
        guard let separator = text.range(of: " \u{B7} ", options: .backwards) else { return false }
        let tail = text[separator.upperBound...].trimmingCharacters(in: .whitespaces)
        return tail.hasPrefix("/") || tail.hasPrefix("~")
    }

    /// A numbered choice, as these CLIs draw permission questions.
    static func isMenuLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first == "❯" || first == ">" || first == "›" else { return false }
        let rest = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
        guard let digit = rest.first, digit.isNumber else { return false }
        let following = rest.dropFirst().first
        return following == "." || following == ")"
    }
}
