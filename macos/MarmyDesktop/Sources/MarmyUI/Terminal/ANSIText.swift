import AppKit
import Foundation

/// Turns terminal output into styled text for the history view.
///
/// Only SGR (colour and emphasis) is understood. Every other escape sequence is
/// dropped rather than acted on: this text is being *shown*, not executed, so a
/// cursor move, a title change, or an OSC 52 clipboard write from an agent's
/// output must have no effect at all.
public enum ANSIText {

    public struct Style: Equatable, Sendable {
        public var foreground: NSColor?
        public var background: NSColor?
        public var bold = false
        public var italic = false
        public var underline = false
        public var inverse = false
        public var faint = false

        public init() {}

        var isPlain: Bool {
            foreground == nil && background == nil && !bold && !italic && !underline && !inverse && !faint
        }
    }

    /// One run of text that shares a style.
    public struct Run: Equatable, Sendable {
        public var text: String
        public var style: Style

        public init(text: String, style: Style) {
            self.text = text
            self.style = style
        }
    }

    /// Splits terminal output into styled runs, dropping control sequences.
    public static func runs(from source: String) -> [Run] {
        var runs: [Run] = []
        var style = Style()
        var pending = ""
        var characters = Array(source)
        var index = 0

        func flush() {
            guard !pending.isEmpty else { return }
            runs.append(Run(text: pending, style: style))
            pending = ""
        }

        while index < characters.count {
            let character = characters[index]
            guard character == "\u{1B}" else {
                // Carriage returns inside captured output only confuse the layout.
                // Swift reads CRLF as one Character, so this works on scalars.
                if character.unicodeScalars.contains("\r") {
                    for scalar in character.unicodeScalars where scalar != "\r" {
                        pending.unicodeScalars.append(scalar)
                    }
                } else {
                    pending.append(character)
                }
                index += 1
                continue
            }

            index += 1
            guard index < characters.count else { break }

            switch characters[index] {
            case "[":
                index += 1
                var parameters = ""
                while index < characters.count, !isFinalCSIByte(characters[index]) {
                    parameters.append(characters[index])
                    index += 1
                }
                let final = index < characters.count ? characters[index] : Character(" ")
                index += 1
                if final == "m" {
                    flush()
                    apply(parameters: parameters, to: &style)
                }
                // Anything else — cursor moves, erases, mode changes — is inert here.

            case "]":
                // OSC: skip to the terminator without ever interpreting it.
                index += 1
                while index < characters.count {
                    if characters[index] == "\u{7}" {
                        index += 1
                        break
                    }
                    if characters[index] == "\u{1B}", index + 1 < characters.count, characters[index + 1] == "\\" {
                        index += 2
                        break
                    }
                    index += 1
                }

            case "P", "X", "^", "_":
                // DCS / SOS / PM / APC strings: skip to the string terminator.
                index += 1
                while index < characters.count {
                    if characters[index] == "\u{1B}", index + 1 < characters.count, characters[index + 1] == "\\" {
                        index += 2
                        break
                    }
                    index += 1
                }

            default:
                // Two-character escapes such as ESC ( B.
                index += 1
            }
        }
        flush()
        return runs
    }

    /// Styled text ready for the history view.
    public static func attributedString(
        from source: String,
        font: NSFont,
        defaultColor: NSColor
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in runs(from: source) {
            var attributes: [NSAttributedString.Key: Any] = [.font: font]
            let style = run.style
            let foreground = style.inverse ? (style.background ?? NSColor.textBackgroundColor)
                : (style.foreground ?? defaultColor)
            let background = style.inverse ? (style.foreground ?? defaultColor) : style.background

            attributes[.foregroundColor] = style.faint ? foreground.withAlphaComponent(0.65) : foreground
            if let background { attributes[.backgroundColor] = background }
            if style.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if style.bold || style.italic {
                var traits: NSFontTraitMask = []
                if style.bold { traits.insert(.boldFontMask) }
                if style.italic { traits.insert(.italicFontMask) }
                attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: traits)
            }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return result
    }

    // MARK: - SGR

    private static func isFinalCSIByte(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
            return true
        }
        return scalar.value >= 0x40 && scalar.value <= 0x7E
    }

    private static func apply(parameters: String, to style: inout Style) {
        // An empty parameter list means SGR 0.
        let trimmed = parameters.hasPrefix("?") ? String(parameters.dropFirst()) : parameters
        let codes = trimmed.isEmpty
            ? [0]
            : trimmed.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }

        var index = 0
        while index < codes.count {
            let code = codes[index]
            switch code {
            case 0: style = Style()
            case 1: style.bold = true
            case 2: style.faint = true
            case 3: style.italic = true
            case 4: style.underline = true
            case 7: style.inverse = true
            case 22: style.bold = false; style.faint = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 27: style.inverse = false
            case 30...37: style.foreground = basic(code - 30, bright: false)
            case 39: style.foreground = nil
            case 40...47: style.background = basic(code - 40, bright: false)
            case 49: style.background = nil
            case 90...97: style.foreground = basic(code - 90, bright: true)
            case 100...107: style.background = basic(code - 100, bright: true)
            case 38, 48:
                let isForeground = (code == 38)
                let (color, consumed) = extendedColor(codes, from: index + 1)
                if isForeground { style.foreground = color } else { style.background = color }
                index += consumed
            default:
                break
            }
            index += 1
        }
    }

    /// `38;5;N` and `38;2;R;G;B`. Returns how many extra codes were used.
    private static func extendedColor(_ codes: [Int], from start: Int) -> (NSColor?, Int) {
        guard start < codes.count else { return (nil, 0) }
        switch codes[start] {
        case 5:
            guard start + 1 < codes.count else { return (nil, 1) }
            return (palette256(codes[start + 1]), 2)
        case 2:
            guard start + 3 < codes.count else { return (nil, codes.count - start) }
            let color = NSColor(
                srgbRed: CGFloat(clamp(codes[start + 1])) / 255,
                green: CGFloat(clamp(codes[start + 2])) / 255,
                blue: CGFloat(clamp(codes[start + 3])) / 255,
                alpha: 1)
            return (color, 4)
        default:
            return (nil, 1)
        }
    }

    private static func clamp(_ value: Int) -> Int { max(0, min(255, value)) }

    static func basic(_ index: Int, bright: Bool) -> NSColor {
        let normal: [UInt32] = [0x1D2026, 0xC0392B, 0x2E8B57, 0x9A7A18, 0x2E6FB8, 0x8E5BB5, 0x2E8B8B, 0xB6BDC6]
        let brightColors: [UInt32] = [0x6B7683, 0xE2796E, 0x4FB3AE, 0xE0A94A, 0x6FA3E6, 0xB98BE0, 0x63C7C7, 0xF2F5F8]
        let table = bright ? brightColors : normal
        guard index >= 0 && index < table.count else { return .textColor }
        return NSColor(marmyHex: table[index])
    }

    static func palette256(_ value: Int) -> NSColor {
        let value = clamp(value)
        if value < 8 { return basic(value, bright: false) }
        if value < 16 { return basic(value - 8, bright: true) }
        if value < 232 {
            let index = value - 16
            let steps: [CGFloat] = [0, 95, 135, 175, 215, 255]
            return NSColor(
                srgbRed: steps[(index / 36) % 6] / 255,
                green: steps[(index / 6) % 6] / 255,
                blue: steps[index % 6] / 255,
                alpha: 1)
        }
        let level = CGFloat(8 + (value - 232) * 10) / 255
        return NSColor(srgbRed: level, green: level, blue: level, alpha: 1)
    }
}
