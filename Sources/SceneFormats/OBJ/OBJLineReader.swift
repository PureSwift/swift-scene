/// Reads a text file a line at a time and each line a token at a time, straight from the bytes, as Wavefront's OBJ
/// and MTL files are read: whitespace-separated keywords and numbers, `#` comments, and `\` continuing a line.
struct OBJLineReader {

    private let bytes: [UInt8]
    private var position = 0
    /// The current line's bytes, comments and continuations removed.
    private(set) var line: [UInt8] = []
    private var cursor = 0
    /// The current line's number, from 1, for errors.
    private(set) var lineNumber = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// Moves to the next line with anything on it; false at the end.
    mutating func nextLine() -> Bool {
        while position < bytes.count {
            line.removeAll(keepingCapacity: true)
            cursor = 0
            var inComment = false
            while position < bytes.count {
                let byte = bytes[position]
                position += 1
                if byte == 0x0A || byte == 0x0D {
                    // A backslash at the end carries the line on.
                    if !inComment, line.last == UInt8(ascii: "\\") {
                        line.removeLast()
                        line.append(0x20)
                        if byte == 0x0D, position < bytes.count, bytes[position] == 0x0A { position += 1 }
                        continue
                    }
                    if byte == 0x0D, position < bytes.count, bytes[position] == 0x0A { position += 1 }
                    break
                }
                if byte == UInt8(ascii: "#") { inComment = true }
                if !inComment { line.append(byte) }
            }
            lineNumber += 1
            skipSpace()
            if cursor < line.count { return true }
        }
        return false
    }

    private mutating func skipSpace() {
        while cursor < line.count, line[cursor] == 0x20 || line[cursor] == 0x09 || line[cursor] == 0x0C || line[cursor] == 0x0B {
            cursor += 1
        }
    }

    var isAtEndOfLine: Bool { cursor >= line.count }

    /// The next whitespace-separated token's bytes.
    mutating func token() -> ArraySlice<UInt8>? {
        skipSpace()
        guard cursor < line.count else { return nil }
        let start = cursor
        while cursor < line.count, line[cursor] != 0x20, line[cursor] != 0x09, line[cursor] != 0x0C, line[cursor] != 0x0B {
            cursor += 1
        }
        return line[start..<cursor]
    }

    /// The next token as a keyword.
    mutating func keyword() -> String? {
        token().map { String(decoding: $0, as: UTF8.self) }
    }

    /// The rest of the line, trimmed: a name or a path, which may have spaces.
    mutating func rest() -> String {
        skipSpace()
        var end = line.count
        while end > cursor, line[end - 1] == 0x20 || line[end - 1] == 0x09 { end -= 1 }
        defer { cursor = line.count }
        return String(decoding: line[cursor..<end], as: UTF8.self)
    }

    /// The next token as a number; nil if there's none or it isn't one.
    mutating func number() -> Float? {
        guard let token = token() else { return nil }
        return Self.parseFloat(token)
    }

    /// The next `count` numbers, or as many as there are.
    mutating func numbers(upTo count: Int) -> [Float] {
        var values: [Float] = []
        while values.count < count, let value = number() { values.append(value) }
        return values
    }

    /// A decimal number: sign, digits, a point, more digits, an exponent. Faster than going through a String, and
    /// enough for what OBJ writers write; anything else falls back to the standard library's parser.
    static func parseFloat(_ token: ArraySlice<UInt8>) -> Float? {
        var i = token.startIndex
        let end = token.endIndex
        guard i < end else { return nil }
        var negative = false
        if token[i] == UInt8(ascii: "-") || token[i] == UInt8(ascii: "+") {
            negative = token[i] == UInt8(ascii: "-")
            i += 1
        }
        var mantissa: UInt64 = 0
        var exponent = 0
        var digits = 0
        while i < end, token[i] >= 0x30, token[i] <= 0x39 {
            if mantissa < 1 << 59 { mantissa = mantissa * 10 + UInt64(token[i] - 0x30) } else { exponent += 1 }
            digits += 1
            i += 1
        }
        if i < end, token[i] == UInt8(ascii: ".") {
            i += 1
            while i < end, token[i] >= 0x30, token[i] <= 0x39 {
                if mantissa < 1 << 59 {
                    mantissa = mantissa * 10 + UInt64(token[i] - 0x30)
                    exponent -= 1
                }
                digits += 1
                i += 1
            }
        }
        guard digits > 0 else {
            return Float(String(decoding: token, as: UTF8.self))
        }
        if i < end, token[i] == UInt8(ascii: "e") || token[i] == UInt8(ascii: "E") {
            i += 1
            var exponentNegative = false
            if i < end, token[i] == UInt8(ascii: "-") || token[i] == UInt8(ascii: "+") {
                exponentNegative = token[i] == UInt8(ascii: "-")
                i += 1
            }
            var value = 0
            var exponentDigits = 0
            while i < end, token[i] >= 0x30, token[i] <= 0x39 {
                value = min(value * 10 + Int(token[i] - 0x30), 10_000)
                exponentDigits += 1
                i += 1
            }
            guard exponentDigits > 0 else { return nil }
            exponent += exponentNegative ? -value : value
        }
        guard i == end else { return Float(String(decoding: token, as: UTF8.self)) }
        var result = Double(mantissa)
        if exponent != 0 { result *= Self.power10(exponent) }
        return Float(negative ? -result : result)
    }

    private static func power10(_ exponent: Int) -> Double {
        var result = 1.0, base = 10.0, e = abs(exponent)
        while e > 0 {
            if e & 1 == 1 { result *= base }
            base *= base
            e >>= 1
        }
        return exponent < 0 ? 1 / result : result
    }

    /// The next token as an integer.
    mutating func integer() -> Int? {
        guard let token = token() else { return nil }
        return Self.parseInteger(token)
    }

    static func parseInteger(_ token: ArraySlice<UInt8>) -> Int? {
        var i = token.startIndex
        guard i < token.endIndex else { return nil }
        var negative = false
        if token[i] == UInt8(ascii: "-") || token[i] == UInt8(ascii: "+") {
            negative = token[i] == UInt8(ascii: "-")
            i += 1
        }
        guard i < token.endIndex else { return nil }
        var value = 0
        while i < token.endIndex {
            let digit = token[i]
            guard digit >= 0x30, digit <= 0x39 else { return nil }
            value = value &* 10 &+ Int(digit - 0x30)
            i += 1
        }
        return negative ? -value : value
    }
}
