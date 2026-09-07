import Foundation

/// Whether text can be put into a prompt without risking running it.
///
/// Pasting into tmux is not automatically inert. A program that has not turned
/// bracketed paste on — a plain shell, say — sees a pasted newline as Return and
/// runs what came before it, even though Marmy never sent Return. tmux exposes
/// no way to ask whether the program in a pane has bracketed paste on, so
/// anything Marmy inserts on its own behalf has to be safe without that
/// knowledge: one line, and no control characters.
///
/// This is only about text Marmy inserts by itself — dictation, a file path, a
/// team update. What a person types, or deliberately sends, is their business.
public enum InsertSafety {

    public enum Refusal: Equatable, Sendable, CustomStringConvertible {
        case multipleLines
        case controlCharacters
        case empty

        public var description: String {
            switch self {
            case .multipleLines:
                return "It has more than one line. A pasted line break can make a shell run the line "
                    + "before it, and Marmy cannot tell from here whether this program would. "
                    + "Nothing was pasted; the text is kept."
            case .controlCharacters:
                return "It contains control characters, which a terminal would act on rather than show. "
                    + "Nothing was pasted; the text is kept."
            case .empty:
                return "There is nothing to paste."
            }
        }
    }

    /// `nil` when the text is safe to insert.
    public static func refusal(for text: String) -> Refusal? {
        guard !text.isEmpty else { return .empty }
        if text.contains("\n") || text.contains("\r") { return .multipleLines }
        for scalar in text.unicodeScalars {
            // No exemptions, Tab included: to a terminal Tab is completion or a
            // change of focus, not a character that lands in the line.
            if scalar.value < 0x20 || scalar.value == 0x7F { return .controlCharacters }
            // A bracketed-paste terminator would end the paste early and let the
            // rest be read as keystrokes.
            if scalar.value == 0x1B { return .controlCharacters }
        }
        return nil
    }

    public static func isSafe(_ text: String) -> Bool {
        refusal(for: text) == nil
    }
}
