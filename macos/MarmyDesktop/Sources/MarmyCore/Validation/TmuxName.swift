import Foundation

/// Rules for tmux session names.
///
/// tmux itself rejects `:` and `.` in session names and treats whitespace as a
/// constant source of quoting bugs in `send-keys` targets, so Marmy keeps names
/// to a conservative alphabet that is always safe to pass as a target.
public enum TmuxName {
    public static let maxLength = 64

    public enum Problem: Hashable, Sendable {
        case empty
        case tooLong(limit: Int)
        case invalidCharacters(String)
        case leadingCharacter

        public var message: String {
            switch self {
            case .empty:
                return "Session name cannot be empty."
            case .tooLong(let limit):
                return "Session name cannot be longer than \(limit) characters."
            case .invalidCharacters(let characters):
                return "Session name cannot contain \(characters). Use letters, digits, hyphen, or underscore."
            case .leadingCharacter:
                return "Session name must start with a letter or digit."
            }
        }
    }

    private static let allowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")

    public static func isValid(_ name: String) -> Bool {
        problem(with: name) == nil
    }

    /// The first thing wrong with `name`, or `nil` when it is usable.
    public static func problem(with name: String) -> Problem? {
        if name.isEmpty { return .empty }
        if name.count > maxLength { return .tooLong(limit: maxLength) }

        let offending = name.unicodeScalars.filter { !allowed.contains($0) }
        if !offending.isEmpty {
            let unique = Array(Set(offending.map { scalar -> String in
                scalar == " " ? "spaces" : "\u{22}\(Character(scalar))\u{22}"
            })).sorted()
            return .invalidCharacters(unique.joined(separator: ", "))
        }

        guard let first = name.first, first.isLetter || first.isNumber else {
            return .leadingCharacter
        }
        return nil
    }

    /// Best-effort conversion of arbitrary text into a valid session name.
    /// Used when deriving names from templates and display names, never to
    /// silently rewrite something the user typed.
    public static func sanitize(_ raw: String) -> String {
        var result = ""
        var lastWasSeparator = false
        for scalar in raw.unicodeScalars {
            if allowed.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasSeparator = (scalar == "-" || scalar == "_")
            } else if !lastWasSeparator && !result.isEmpty {
                result.append("-")
                lastWasSeparator = true
            }
        }
        while let first = result.first, !(first.isLetter || first.isNumber) {
            result.removeFirst()
        }
        while let last = result.last, last == "-" || last == "_" {
            result.removeLast()
        }
        if result.isEmpty { result = "agent" }
        if result.count > maxLength {
            result = String(result.prefix(maxLength))
            while let last = result.last, last == "-" || last == "_" {
                result.removeLast()
            }
        }
        return result
    }
}
