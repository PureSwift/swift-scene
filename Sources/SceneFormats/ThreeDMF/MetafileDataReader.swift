// Ported from Quesa's 3DMF readers (E3FFR_3DMF_Bin.cpp, E3FFR_3DMF_Text.cpp, E3IOData.cpp).
// Copyright (c) 1999-2021, Quesa Developers. All rights reserved.
// Licensed under the BSD 3-Clause License; see LICENSE-Quesa.

import BinaryParsing

/// Reads the values of an object's data in order, whichever encoding it is in: big- or little-endian binary, or
/// a text metafile's tokens. An object's reader asks for what it expects, as Quesa's read methods do.
///
/// Binary data is parsed with swift-binary-parsing: each read parses within the object's range of the file, which it
/// advances, so nothing reads past the object and nothing is copied out of the file first.
struct MetafileDataReader {

    private let data: MetafileObjectData
    /// For binary data, what's left of the object's range.
    private var range: ParserRange?
    /// For text, the next token.
    private var position = 0

    init(_ data: MetafileObjectData) {
        self.data = data
        if case .binary(let binary) = data { range = binary.range }
    }

    var isAtEnd: Bool {
        switch data {
        case .binary: range?.isEmpty ?? true
        case .text(let tokens): position >= tokens.count
        }
    }

    /// Parses the next value of binary data, advancing past it.
    private mutating func parse<T>(_ body: (inout ParserSpan, Endianness) throws(ParsingError) -> T) throws(SceneFormatError) -> T {
        guard case .binary(let binary) = data, var remaining = range else { preconditionFailure("Binary only") }
        let endianness: Endianness = binary.byteOrder == .bigEndian ? .big : .little
        do {
            let value = try binary.file.withParserSpan(usingRange: &remaining) { (span) throws(ParsingError) in
                try body(&span, endianness)
            }
            range = remaining
            return value
        } catch {
            throw SceneFormatError(error)
        }
    }

    // MARK: Numbers

    mutating func uint32() throws(SceneFormatError) -> UInt32 {
        switch data {
        case .binary:
            return try parse { (span, endianness) throws(ParsingError) in try UInt32(parsing: &span, endianness: endianness) }
        case .text:
            let value = try integer()
            guard let result = UInt32(exactly: value) ?? (value < 0 ? UInt32(bitPattern: Int32(truncatingIfNeeded: value)) : nil) else {
                throw .malformed("\(value) is out of range", offset: nil)
            }
            return result
        }
    }

    mutating func int32() throws(SceneFormatError) -> Int32 {
        Int32(bitPattern: try uint32())
    }

    mutating func uint16() throws(SceneFormatError) -> UInt16 {
        switch data {
        case .binary: try parse { (span, endianness) throws(ParsingError) in try UInt16(parsing: &span, endianness: endianness) }
        case .text: UInt16(truncatingIfNeeded: try integer())
        }
    }

    mutating func uint8() throws(SceneFormatError) -> UInt8 {
        switch data {
        case .binary: try parse { (span, _) throws(ParsingError) in try UInt8(parsing: &span) }
        case .text: UInt8(truncatingIfNeeded: try integer())
        }
    }

    mutating func int8() throws(SceneFormatError) -> Int8 {
        Int8(bitPattern: try uint8())
    }

    mutating func uint64() throws(SceneFormatError) -> UInt64 {
        switch data {
        case .binary:
            // Two 32-bit words in the file's order, which is the order of a 64-bit number.
            return try parse { (span, endianness) throws(ParsingError) in try UInt64(parsing: &span, endianness: endianness) }
        case .text:
            return UInt64(truncatingIfNeeded: try integer())
        }
    }

    mutating func float32() throws(SceneFormatError) -> Float {
        switch data {
        case .binary:
            return Float(bitPattern: try uint32())
        case .text(let tokens):
            // Some writers separate numbers with commas, which Quesa's scanf-style reading stops at.
            let token = Self.number(try nextToken(tokens))
            if let value = Float(token) { return value }
            // Some writers spell integers in hexadecimal, and some floats with a trailing f.
            if let value = Self.parseInteger(token) { return Float(value) }
            if token.hasSuffix("f") || token.hasSuffix("F"), let value = Float(token.dropLast()) { return value }
            throw .malformed("\"\(token)\" is not a number", offset: nil)
        }
    }

    mutating func floats(_ count: Int) throws(SceneFormatError) -> [Float] {
        var values: [Float] = []
        values.reserveCapacity(count)
        for _ in 0..<count { values.append(try float32()) }
        return values
    }

    mutating func vector3() throws(SceneFormatError) -> SIMD3<Float> {
        SIMD3(try float32(), try float32(), try float32())
    }

    // MARK: Flags and names

    /// A boolean: a 32-bit number in binary, `True` or `False` in text.
    mutating func boolean() throws(SceneFormatError) -> Bool {
        try enumerated(["false": 0, "true": 1]) != 0
    }

    /// An enumerated value: a 32-bit number in binary, a constant's name in text (or several joined by `|`, OR-ed).
    mutating func enumerated(_ names: [String: UInt32]) throws(SceneFormatError) -> UInt32 {
        guard case .text(let tokens) = data else { return try uint32() }
        var value: UInt32 = 0
        repeat {
            let token = try nextToken(tokens)
            if let known = names[token.lowercased()] {
                value |= known
            } else if let number = Self.parseInteger(token) {
                value |= UInt32(truncatingIfNeeded: number)
            } else {
                throw .malformed("Unknown constant \"\(token)\"", offset: nil)
            }
            guard position < tokens.count, tokens[position] == "|" else { break }
            position += 1
        } while true
        return value
    }

    /// A string: null-terminated and padded to four bytes in binary, quoted in text.
    mutating func string() throws(SceneFormatError) -> String {
        switch data {
        case .binary(let binary):
            let start = binary.range.lowerBound
            return try parse { (span, _) throws(ParsingError) in
                var utf8: [UInt8] = []
                while true {
                    let byte = try UInt8(parsing: &span)
                    if byte == 0 { break }
                    utf8.append(byte)
                }
                try Self.skipPadding(&span, objectStart: start)
                return String(decoding: utf8, as: UTF8.self)
            }
        case .text(let tokens):
            let token = try nextToken(tokens)
            guard token.count >= 2, token.first == "\"", token.last == "\"" else { return token }
            return Self.unescape(token.dropFirst().dropLast())
        }
    }

    /// Raw bytes: `count` of them padded to four in binary, hexadecimal runs (`0x…`) in text.
    mutating func rawBytes(_ count: Int) throws(SceneFormatError) -> [UInt8] {
        switch data {
        case .binary(let binary):
            let start = binary.range.lowerBound
            return try parse { (span, _) throws(ParsingError) in
                let raw = try span.sliceSpan(byteCount: count).withUnsafeBytes { Array($0) }
                try Self.skipPadding(&span, objectStart: start)
                return raw
            }
        case .text(let tokens):
            var raw: [UInt8] = []
            raw.reserveCapacity(count)
            while raw.count < count, position < tokens.count {
                var digits = Substring(tokens[position])
                guard digits.hasPrefix("0x") || digits.hasPrefix("0X") else { break }
                position += 1
                digits = digits.dropFirst(2)
                var index = digits.startIndex
                while index < digits.endIndex, raw.count < count {
                    let next = digits.index(index, offsetBy: 2, limitedBy: digits.endIndex) ?? digits.endIndex
                    guard let byte = UInt8(digits[index..<next], radix: 16) else {
                        throw .malformed("Bad hexadecimal \"\(tokens[position - 1])\"", offset: nil)
                    }
                    raw.append(byte)
                    index = next
                }
            }
            // A writer may leave out padding at the end; what's missing reads as zero.
            if raw.count < count { raw.append(contentsOf: repeatElement(0, count: count - raw.count)) }
            return raw
        }
    }

    // MARK: Helpers

    /// Moves past padding to the next multiple of four bytes from the object's start, as far as the object goes.
    private static func skipPadding(_ span: inout ParserSpan, objectStart: Int) throws(ParsingError) {
        let consumed = span.startPosition - objectStart
        let padding = min(padded(consumed) - consumed, span.count)
        if padding > 0 { try span.seek(toRelativeOffset: padding) }
    }

    private mutating func nextToken(_ tokens: [String]) throws(SceneFormatError) -> String {
        guard position < tokens.count else { throw .unexpectedEndOfData(offset: position) }
        defer { position += 1 }
        return tokens[position]
    }

    private mutating func integer() throws(SceneFormatError) -> Int64 {
        guard case .text(let tokens) = data else { preconditionFailure("Text only") }
        let token = Self.number(try nextToken(tokens))
        if let value = Self.parseInteger(token) { return value }
        // A float where an integer belongs, as some writers put them.
        if let value = Float(token), value.isFinite { return Int64(value) }
        throw .malformed("\"\(token)\" is not an integer", offset: nil)
    }

    /// A number's token without the commas some writers put after it.
    private static func number(_ token: String) -> String {
        var trimmed = Substring(token)
        while trimmed.hasSuffix(",") { trimmed = trimmed.dropLast() }
        return String(trimmed)
    }

    static func parseInteger(_ token: String) -> Int64? {
        if token.hasPrefix("0x") || token.hasPrefix("0X") {
            return UInt64(token.dropFirst(2), radix: 16).map { Int64(bitPattern: $0) }
        }
        if token.hasPrefix("-0x") || token.hasPrefix("-0X") {
            return Int64(token.dropFirst(3), radix: 16).map { -$0 }
        }
        return Int64(token)
    }

    static func padded(_ offset: Int) -> Int {
        (offset + 3) & ~3
    }

    private static func unescape(_ string: Substring) -> String {
        guard string.contains("\\") else { return String(string) }
        var result = ""
        var escaped = false
        for character in string {
            if escaped {
                switch character {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": result.append("\r")
                default: result.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        return result
    }
}
