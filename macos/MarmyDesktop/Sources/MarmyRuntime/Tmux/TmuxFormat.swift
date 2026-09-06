import Foundation

/// Length-prefixed tmux `-F` formats.
///
/// A session name, window name, or working directory can legally contain a
/// newline or any separator byte we might pick, so nothing is delimited by
/// value. Each field is emitted as `#{n:field}:#{field}` — a byte count, a
/// colon, then exactly that many bytes — and parsed back by counting bytes.
public enum TmuxFormat {

    /// The `-F` argument for a list of tmux format variables.
    public static func lengthPrefixed(_ fields: [String]) -> String {
        fields.map { "#{n:\($0)}:#{\($0)}" }.joined()
    }

    /// Splits output into records of `fieldCount` fields.
    ///
    /// Anything that does not parse exactly is an error: a dropped row would
    /// silently hide a running agent, and a defaulted number would invent state.
    public static func parseRecords(
        _ data: Data,
        fieldCount: Int,
        command: String
    ) throws -> [[String]] {
        let bytes = [UInt8](data)
        var index = 0
        var records: [[String]] = []

        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "\n") {
                index += 1
                continue
            }
            var fields: [String] = []
            fields.reserveCapacity(fieldCount)

            for _ in 0..<fieldCount {
                var length = 0
                var digits = 0
                while index < bytes.count, bytes[index] >= UInt8(ascii: "0"), bytes[index] <= UInt8(ascii: "9") {
                    length = length * 10 + Int(bytes[index] - UInt8(ascii: "0"))
                    digits += 1
                    index += 1
                }
                guard digits > 0, index < bytes.count, bytes[index] == UInt8(ascii: ":") else {
                    throw TmuxError.unexpectedOutput(command: command, output: preview(data))
                }
                index += 1
                guard index + length <= bytes.count else {
                    throw TmuxError.unexpectedOutput(command: command, output: preview(data))
                }
                fields.append(String(decoding: bytes[index..<(index + length)], as: UTF8.self))
                index += length
            }

            if index < bytes.count {
                guard bytes[index] == UInt8(ascii: "\n") else {
                    throw TmuxError.unexpectedOutput(command: command, output: preview(data))
                }
                index += 1
            }
            records.append(fields)
        }
        return records
    }

    /// Exactly one record, for commands that describe a single thing.
    public static func parseRecord(
        _ data: Data,
        fieldCount: Int,
        command: String
    ) throws -> [String] {
        let records = try parseRecords(data, fieldCount: fieldCount, command: command)
        guard records.count == 1 else {
            throw TmuxError.unexpectedOutput(command: command, output: preview(data))
        }
        return records[0]
    }

    /// A numeric field that must be a number. tmux always emits one; if it did
    /// not, guessing zero would be worse than saying so.
    public static func integer(_ value: String, command: String) throws -> Int {
        guard let number = Int(value) else {
            throw TmuxError.unexpectedOutput(command: command, output: value)
        }
        return number
    }

    private static func preview(_ data: Data) -> String {
        let text = String(decoding: data.prefix(200), as: UTF8.self)
        return text.isEmpty ? "<empty>" : text
    }
}

/// tmux target syntax.
///
/// Stable ids are always preferred. When a name has to be used, session-target
/// commands take `=name` and pane-target commands (send-keys, capture-pane,
/// set-option) need the trailing colon form `=name:`.
public enum TmuxTarget {
    public static func session(name: String) -> String { "=\(name)" }
    public static func pane(inSessionNamed name: String) -> String { "=\(name):" }
}
