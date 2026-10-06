import Foundation

public enum OrderedJSONError: Error, Equatable {
    case invalid(offset: Int)
}

/// A JSON value that keeps object key order and number spelling, so a settings file can be edited with a minimal diff.
public indirect enum OrderedJSON: Equatable, Sendable {
    public struct Member: Equatable, Sendable {
        public var key: String
        public var value: OrderedJSON

        public init(key: String, value: OrderedJSON) {
            self.key = key
            self.value = value
        }
    }

    case object([Member])
    case array([OrderedJSON])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    public static func parse(_ text: String) throws -> OrderedJSON {
        var parser = Parser(bytes: Array(text.utf8))
        parser.skipWhitespace()
        let value = try parser.value()
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw OrderedJSONError.invalid(offset: parser.index) }
        return value
    }

    public subscript(key: String) -> OrderedJSON? {
        guard case let .object(members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    public func setting(_ key: String, to value: OrderedJSON) -> OrderedJSON {
        guard case var .object(members) = self else { return self }
        if let index = members.firstIndex(where: { $0.key == key }) {
            members[index].value = value
        } else {
            members.append(Member(key: key, value: value))
        }
        return .object(members)
    }

    public func removing(_ key: String) -> OrderedJSON {
        guard case let .object(members) = self else { return self }
        return .object(members.filter { $0.key != key })
    }

    /// `JSON.stringify(value, null, 2)`, the format Claude Code writes its settings in.
    public func printed() -> String {
        var out = ""
        write(into: &out, level: 0)
        return out
    }

    private func write(into out: inout String, level: Int) {
        let pad = String(repeating: "  ", count: level + 1)
        let closing = String(repeating: "  ", count: level)
        switch self {
        case let .object(members):
            guard !members.isEmpty else { out += "{}"; return }
            out += "{\n"
            for (index, member) in members.enumerated() {
                out += pad + Self.quoted(member.key) + ": "
                member.value.write(into: &out, level: level + 1)
                out += index < members.count - 1 ? ",\n" : "\n"
            }
            out += closing + "}"
        case let .array(items):
            guard !items.isEmpty else { out += "[]"; return }
            out += "[\n"
            for (index, item) in items.enumerated() {
                out += pad
                item.write(into: &out, level: level + 1)
                out += index < items.count - 1 ? ",\n" : "\n"
            }
            out += closing + "]"
        case let .string(text): out += Self.quoted(text)
        case let .number(raw): out += raw
        case let .bool(flag): out += flag ? "true" : "false"
        case .null: out += "null"
        }
    }

    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{8}": out += "\\b"
            case "\u{C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}

private struct Parser {
    let bytes: [UInt8]
    var index = 0

    private var invalid: OrderedJSONError {
        .invalid(offset: index)
    }

    private func peek(_ character: Unicode.Scalar) -> Bool {
        index < bytes.count && bytes[index] == UInt8(ascii: character)
    }

    mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[index]) {
            index += 1
        }
    }

    mutating func value() throws -> OrderedJSON {
        guard index < bytes.count else { throw invalid }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try object()
        case UInt8(ascii: "["): return try array()
        case UInt8(ascii: "\""): return try .string(string())
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "n"): try literal("null"); return .null
        default: return try .number(number())
        }
    }

    private mutating func literal(_ word: String) throws {
        let expected = Array(word.utf8)
        guard index + expected.count <= bytes.count, Array(bytes[index ..< index + expected.count]) == expected else { throw invalid }
        index += expected.count
    }

    private mutating func object() throws -> OrderedJSON {
        index += 1
        var members: [OrderedJSON.Member] = []
        skipWhitespace()
        if peek("}") {
            index += 1
            return .object([])
        }
        while true {
            skipWhitespace()
            guard peek("\"") else { throw invalid }
            let key = try string()
            skipWhitespace()
            guard peek(":") else { throw invalid }
            index += 1
            skipWhitespace()
            try members.append(OrderedJSON.Member(key: key, value: value()))
            skipWhitespace()
            if peek(",") {
                index += 1
            } else if peek("}") {
                index += 1
                return .object(members)
            } else {
                throw invalid
            }
        }
    }

    private mutating func array() throws -> OrderedJSON {
        index += 1
        var items: [OrderedJSON] = []
        skipWhitespace()
        if peek("]") {
            index += 1
            return .array([])
        }
        while true {
            skipWhitespace()
            try items.append(value())
            skipWhitespace()
            if peek(",") {
                index += 1
            } else if peek("]") {
                index += 1
                return .array(items)
            } else {
                throw invalid
            }
        }
    }

    private mutating func string() throws -> String {
        index += 1
        var result = ""
        var start = index
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                result += String(decoding: bytes[start ..< index], as: UTF8.self)
                index += 1
                return result
            }
            if byte < 0x20 {
                throw invalid
            }
            if byte == UInt8(ascii: "\\") {
                result += String(decoding: bytes[start ..< index], as: UTF8.self)
                index += 1
                try result.unicodeScalars.append(contentsOf: escape())
                start = index
                continue
            }
            index += 1
        }
        throw invalid
    }

    /// The scalars of one escape sequence, `index` on the character after the backslash; leaves it after the sequence.
    private mutating func escape() throws -> [Unicode.Scalar] {
        guard index < bytes.count else { throw invalid }
        let simple: [UInt8: Unicode.Scalar] = [
            UInt8(ascii: "\""): "\"", UInt8(ascii: "\\"): "\\", UInt8(ascii: "/"): "/", UInt8(ascii: "b"): "\u{8}",
            UInt8(ascii: "f"): "\u{C}", UInt8(ascii: "n"): "\n", UInt8(ascii: "r"): "\r", UInt8(ascii: "t"): "\t",
        ]
        if let scalar = simple[bytes[index]] {
            index += 1
            return [scalar]
        }
        guard bytes[index] == UInt8(ascii: "u") else { throw invalid }
        index += 1
        let high = try hex4()
        if (0xD800 ..< 0xDC00).contains(high), peek("\\"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "u") {
            index += 2
            let low = try hex4()
            guard (0xDC00 ..< 0xE000).contains(low),
                  let scalar = Unicode.Scalar(0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)) else { throw invalid }
            return [scalar]
        }
        guard let scalar = Unicode.Scalar(high) else { throw invalid }
        return [scalar]
    }

    private mutating func hex4() throws -> UInt32 {
        guard index + 4 <= bytes.count, let value = UInt32(String(decoding: bytes[index ..< index + 4], as: UTF8.self), radix: 16)
        else { throw invalid }
        index += 4
        return value
    }

    private mutating func number() throws -> String {
        let start = index
        let allowed = Set("-+.eE0123456789".utf8)
        while index < bytes.count, allowed.contains(bytes[index]) {
            index += 1
        }
        let raw = String(decoding: bytes[start ..< index], as: UTF8.self)
        guard !raw.isEmpty, Double(raw) != nil else { throw invalid }
        return raw
    }
}
