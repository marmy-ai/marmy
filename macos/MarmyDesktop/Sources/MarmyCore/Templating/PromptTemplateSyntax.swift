import Foundation

/// Anything wrong with a prompt template, reported with the line it happened on
/// so the editor can point at it.
public enum PromptTemplateError: Error, Equatable, Sendable, CustomStringConvertible {
    case unterminatedTag(line: Int)
    case emptyTag(line: Int)
    case invalidIdentifier(String, line: Int)
    case unclosedSection(String, line: Int)
    case unexpectedSectionEnd(String, line: Int)
    case mismatchedSectionEnd(expected: String, found: String, line: Int)
    case unknownVariable(String, line: Int)

    public var line: Int {
        switch self {
        case .unterminatedTag(let line), .emptyTag(let line):
            return line
        case .invalidIdentifier(_, let line), .unclosedSection(_, let line),
             .unexpectedSectionEnd(_, let line), .unknownVariable(_, let line):
            return line
        case .mismatchedSectionEnd(_, _, let line):
            return line
        }
    }

    public var description: String {
        switch self {
        case .unterminatedTag(let line):
            return "Line \(line): a {{ tag is never closed with }}."
        case .emptyTag(let line):
            return "Line \(line): empty {{}} tag."
        case .invalidIdentifier(let name, let line):
            return "Line \(line): \u{22}\(name)\u{22} is not a valid variable name."
        case .unclosedSection(let name, let line):
            return "Line \(line): section {{#\(name)}} is never closed."
        case .unexpectedSectionEnd(let name, let line):
            return "Line \(line): {{/\(name)}} closes a section that was never opened."
        case .mismatchedSectionEnd(let expected, let found, let line):
            return "Line \(line): expected {{/\(expected)}} but found {{/\(found)}}."
        case .unknownVariable(let name, let line):
            return "Line \(line): unknown variable {{\(name)}}."
        }
    }
}

/// Values a template is rendered against.
///
/// A variable is either present with text or absent. Blank text counts as
/// absent for sections, which is what makes `{{#manager.name}}…{{/manager.name}}`
/// read correctly for a root agent.
public struct PromptRenderContext: Hashable, Sendable {
    public private(set) var values: [String: String]

    public init(_ values: [String: String] = [:]) {
        self.values = values
    }

    public subscript(key: String) -> String? {
        get { values[key] }
        set { values[key] = newValue }
    }

    public var keys: Set<String> { Set(values.keys) }

    public func text(for key: String) -> String? { values[key] }

    public func isPresent(_ key: String) -> Bool {
        guard let value = values[key] else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// A tiny, deliberately boring template language: `{{variable}}`,
/// `{{#section}}…{{/section}}` (render when present), and
/// `{{^section}}…{{/section}}` (render when absent). No loops, no expressions,
/// no partials — rendering the same template against the same context always
/// produces the same string.
public enum PromptTemplateSyntax {

    enum Segment: Equatable {
        case literal(String)
        case variable(name: String, line: Int)
        case section(name: String, inverted: Bool, body: [Segment], line: Int)
    }

    // MARK: - Public API

    /// Renders a template. Throws on malformed syntax or a variable the context
    /// does not define, rather than silently emitting an empty string.
    public static func render(_ source: String, context: PromptRenderContext) throws -> String {
        let segments = try parse(source)
        var output = ""
        try render(segments, context: context, into: &output)
        return output
    }

    /// Every variable and section name a template mentions, in first-use order.
    public static func referencedVariables(in source: String) throws -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        collect(try parse(source), into: &ordered, seen: &seen)
        return ordered
    }

    /// Parses a template and reports the first name it uses that is not in
    /// `knownVariables`. Used by the validator so a bad template is caught while
    /// editing, not at launch.
    public static func validate(_ source: String, knownVariables: Set<String>) throws {
        let segments = try parse(source)
        try validate(segments, knownVariables: knownVariables)
    }

    /// True when `name` is a legal variable identifier: dot-separated segments
    /// of letters, digits, and underscores, each starting with a letter.
    public static func isValidIdentifier(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return false }
        for part in parts {
            guard let first = part.first, first.isLetter else { return false }
            guard part.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return false }
        }
        return true
    }

    // MARK: - Rendering

    private static func render(_ segments: [Segment], context: PromptRenderContext, into output: inout String) throws {
        for segment in segments {
            switch segment {
            case .literal(let text):
                output += text
            case .variable(let name, let line):
                guard let value = context.text(for: name) else {
                    throw PromptTemplateError.unknownVariable(name, line: line)
                }
                output += value
            case .section(let name, let inverted, let body, let line):
                guard context.keys.contains(name) else {
                    throw PromptTemplateError.unknownVariable(name, line: line)
                }
                if context.isPresent(name) != inverted {
                    try render(body, context: context, into: &output)
                }
            }
        }
    }

    private static func collect(_ segments: [Segment], into ordered: inout [String], seen: inout Set<String>) {
        for segment in segments {
            switch segment {
            case .literal:
                continue
            case .variable(let name, _):
                if seen.insert(name).inserted { ordered.append(name) }
            case .section(let name, _, let body, _):
                if seen.insert(name).inserted { ordered.append(name) }
                collect(body, into: &ordered, seen: &seen)
            }
        }
    }

    private static func validate(_ segments: [Segment], knownVariables: Set<String>) throws {
        for segment in segments {
            switch segment {
            case .literal:
                continue
            case .variable(let name, let line):
                if !knownVariables.contains(name) {
                    throw PromptTemplateError.unknownVariable(name, line: line)
                }
            case .section(let name, _, let body, let line):
                if !knownVariables.contains(name) {
                    throw PromptTemplateError.unknownVariable(name, line: line)
                }
                try validate(body, knownVariables: knownVariables)
            }
        }
    }

    // MARK: - Parsing

    static func parse(_ source: String) throws -> [Segment] {
        var parser = Parser(source: source)
        let segments = try parser.parseSegments(closing: nil)
        return segments
    }

    private struct Parser {
        let characters: [Character]
        var index = 0
        var line = 1

        init(source: String) {
            self.characters = Array(source)
        }

        mutating func parseSegments(closing expected: (name: String, line: Int)?) throws -> [Segment] {
            var segments: [Segment] = []
            var literal = ""

            func flush() {
                if !literal.isEmpty {
                    segments.append(.literal(literal))
                    literal = ""
                }
            }

            while index < characters.count {
                guard let tagStart = nextTagStart(from: index) else {
                    literal += consume(upTo: characters.count)
                    break
                }
                literal += consume(upTo: tagStart)
                let tagLine = line
                index += 2  // "{{"

                guard let closeIndex = findTagEnd(from: index) else {
                    throw PromptTemplateError.unterminatedTag(line: tagLine)
                }
                let rawTag = String(characters[index..<closeIndex])
                advance(to: closeIndex + 2)

                let tag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let marker = tag.first else {
                    throw PromptTemplateError.emptyTag(line: tagLine)
                }

                switch marker {
                case "#", "^", "/":
                    let name = String(tag.dropFirst()).trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { throw PromptTemplateError.emptyTag(line: tagLine) }
                    guard PromptTemplateSyntax.isValidIdentifier(name) else {
                        throw PromptTemplateError.invalidIdentifier(name, line: tagLine)
                    }
                    // A section tag alone on its line contributes no whitespace.
                    if isStandaloneTag(startingAt: tagStart) {
                        literal = trimTrailingInlineWhitespace(literal)
                        skipToNextLine()
                    }
                    if marker == "/" {
                        guard let expected else {
                            throw PromptTemplateError.unexpectedSectionEnd(name, line: tagLine)
                        }
                        guard expected.name == name else {
                            throw PromptTemplateError.mismatchedSectionEnd(
                                expected: expected.name, found: name, line: tagLine)
                        }
                        flush()
                        return segments
                    }
                    flush()
                    let body = try parseSegments(closing: (name: name, line: tagLine))
                    segments.append(.section(name: name, inverted: marker == "^", body: body, line: tagLine))
                default:
                    guard PromptTemplateSyntax.isValidIdentifier(tag) else {
                        throw PromptTemplateError.invalidIdentifier(tag, line: tagLine)
                    }
                    flush()
                    segments.append(.variable(name: tag, line: tagLine))
                }
            }

            if let expected {
                throw PromptTemplateError.unclosedSection(expected.name, line: expected.line)
            }
            flush()
            return segments
        }

        // MARK: Scanning helpers

        private func nextTagStart(from start: Int) -> Int? {
            var i = start
            while i + 1 < characters.count {
                if characters[i] == "{" && characters[i + 1] == "{" { return i }
                i += 1
            }
            return nil
        }

        private func findTagEnd(from start: Int) -> Int? {
            var i = start
            while i + 1 < characters.count {
                if characters[i] == "}" && characters[i + 1] == "}" { return i }
                i += 1
            }
            return nil
        }

        private mutating func consume(upTo end: Int) -> String {
            let slice = characters[index..<end]
            line += slice.filter { $0 == "\n" }.count
            index = end
            return String(slice)
        }

        private mutating func advance(to end: Int) {
            _ = consume(upTo: min(end, characters.count))
        }

        /// True when nothing but whitespace shares the tag's line in the source.
        ///
        /// This reads the original source around the tag rather than the pending
        /// literal: the literal is flushed whenever a variable is emitted, and an
        /// empty literal would otherwise look like the start of a line and eat a
        /// newline that belongs to the output.
        private func isStandaloneTag(startingAt tagStart: Int) -> Bool {
            var before = tagStart - 1
            while before >= 0, characters[before] == " " || characters[before] == "\t" { before -= 1 }
            guard before < 0 || characters[before] == "\n" else { return false }

            var after = index
            while after < characters.count, characters[after] == " " || characters[after] == "\t" { after += 1 }
            return after >= characters.count || characters[after] == "\n"
        }

        private func trimTrailingInlineWhitespace(_ text: String) -> String {
            var result = text
            while let last = result.last, last == " " || last == "\t" {
                result.removeLast()
            }
            return result
        }

        private mutating func skipToNextLine() {
            var i = index
            while i < characters.count, characters[i] == " " || characters[i] == "\t" { i += 1 }
            if i < characters.count, characters[i] == "\n" { i += 1 }
            advance(to: i)
        }
    }
}
