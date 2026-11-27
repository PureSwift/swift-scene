import SceneFormats

/// A streaming UTF-8 lexer. Offsets are bytes in the original file, including its header.
struct USDALexer {
    enum Kind: Equatable {
        case identifier(String), number(String), string(String), asset(String), path(String)
        case punctuation(UInt8), end
    }
    struct Token {
        let kind: Kind
        let offset: Int
    }

    let bytes: [UInt8]
    private(set) var cursor: Int

    init(bytes: [UInt8]) throws(SceneFormatError) {
        guard String(validating: bytes, as: UTF8.self) != nil else {
            throw .malformed("USDA is not valid UTF-8", offset: nil)
        }
        let end = bytes.firstIndex(of: 10) ?? bytes.count
        var header = Array(bytes[..<end])
        while let last = header.last, [9, 13, 32].contains(last) { header.removeLast() }
        guard header == Array("#usda 1.0".utf8) else {
            throw .invalidHeader("Expected #usda 1.0")
        }
        self.bytes = bytes
        cursor = min(end + 1, bytes.count)
    }

    mutating func next() throws(SceneFormatError) -> Token {
        while cursor < bytes.count {
            if [9, 10, 13, 32].contains(bytes[cursor]) { cursor += 1 }
            else if bytes[cursor] == 35 {
                while cursor < bytes.count, bytes[cursor] != 10 { cursor += 1 }
            } else { break }
        }
        let start = cursor
        guard cursor < bytes.count else { return Token(kind: .end, offset: cursor) }
        let byte = bytes[cursor]
        let kind: Kind
        if byte == 34 || byte == 39 {
            kind = .string(try quoted())
        } else if byte == 64 || byte == 60 {
            cursor += 1
            let begin = cursor
            let closing: UInt8 = byte == 64 ? 64 : 62
            if byte == 64, cursor + 1 < bytes.count, bytes[cursor] == 64, bytes[cursor + 1] == 64 {
                throw .unsupported("Triple-delimited USDA asset paths")
            }
            while cursor < bytes.count, bytes[cursor] != closing {
                guard bytes[cursor] >= 32 else { throw .malformed("Control character in USDA path", offset: cursor) }
                cursor += 1
            }
            guard cursor < bytes.count else { throw .unexpectedEndOfData(offset: cursor) }
            let value = String(decoding: bytes[begin..<cursor], as: UTF8.self)
            cursor += 1
            kind = byte == 64 ? .asset(value) : .path(value)
        } else if Self.isStart(byte) {
            cursor += 1
            while cursor < bytes.count, Self.isContinue(bytes[cursor]) || bytes[cursor] == 58 { cursor += 1 }
            let word = String(decoding: bytes[start..<cursor], as: UTF8.self)
            kind = ["inf", "nan"].contains(word) ? .number(word) : .identifier(word)
        } else if (48...57).contains(byte) || byte == 45 || byte == 43
                    || (byte == 46 && cursor + 1 < bytes.count && (48...57).contains(bytes[cursor + 1])) {
            cursor += 1
            while cursor < bytes.count, (48...57).contains(bytes[cursor])
                    || [46, 101, 69, 43, 45, 105, 110, 102, 97].contains(bytes[cursor]) { cursor += 1 }
            let number = String(decoding: bytes[start..<cursor], as: UTF8.self)
            guard Self.isNumber(number) else { throw .malformed("Invalid USDA number", offset: start) }
            kind = .number(number)
        } else if Array("{}()[]=,;.:".utf8).contains(byte) {
            cursor += 1
            kind = .punctuation(byte)
        } else if byte >= 128 {
            throw .unsupported("Non-ASCII USDA identifiers")
        } else {
            throw .malformed("Unexpected USDA character", offset: start)
        }
        return Token(kind: kind, offset: start)
    }

    static func isStart(_ byte: UInt8) -> Bool {
        byte == 95 || (65...90).contains(byte) || (97...122).contains(byte)
    }

    static func isContinue(_ byte: UInt8) -> Bool { isStart(byte) || (48...57).contains(byte) }

    static func isIdentifier(_ name: String, namespaced: Bool = false) -> Bool {
        let parts = namespaced ? name.split(separator: ":", omittingEmptySubsequences: false) : [Substring(name)]
        return parts.allSatisfy { part in
            guard let first = part.utf8.first, isStart(first) else { return false }
            return part.utf8.allSatisfy(isContinue)
        }
    }

    private static func isNumber(_ number: String) -> Bool {
        if ["inf", "-inf", "+inf", "nan", "-nan", "+nan"].contains(number) { return true }
        // Double's parser validates decimal syntax, but overflow must not become infinity.
        guard let value = Double(number), value.isFinite else { return false }
        return number.utf8.contains { (48...57).contains($0) }
    }

    private mutating func quoted() throws(SceneFormatError) -> String {
        let quote = bytes[cursor]
        let triple = cursor + 2 < bytes.count && bytes[cursor + 1] == quote && bytes[cursor + 2] == quote
        cursor += triple ? 3 : 1
        var result: [UInt8] = []
        while cursor < bytes.count {
            let byte = bytes[cursor]
            if byte == quote, !triple || (cursor + 2 < bytes.count && bytes[cursor + 1] == quote && bytes[cursor + 2] == quote) {
                cursor += triple ? 3 : 1
                return String(decoding: result, as: UTF8.self)
            }
            guard byte != 0, triple || (byte != 10 && byte != 13) else {
                throw .malformed("Invalid character in USDA string", offset: cursor)
            }
            cursor += 1
            if byte != 92 { result.append(byte); continue }
            guard cursor < bytes.count else { throw .unexpectedEndOfData(offset: cursor) }
            let escaped = bytes[cursor]
            cursor += 1
            switch escaped {
            case 34, 39, 92: result.append(escaped)
            case 110: result.append(10)
            case 114: result.append(13)
            case 116: result.append(9)
            case 98: result.append(8)
            case 102: result.append(12)
            case 97: result.append(7)
            case 118: result.append(11)
            default: throw .unsupported("USDA string escape at byte \(cursor - 2)")
            }
        }
        throw .unexpectedEndOfData(offset: cursor)
    }
}
