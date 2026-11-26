// Ported from Quesa's 3DMF readers (E3FFR_3DMF_Bin.cpp, E3FFR_3DMF_Text.cpp, E3IOData.cpp).
// Copyright (c) 1999-2021, Quesa Developers. All rights reserved.
// Licensed under the BSD 3-Clause License; see LICENSE-Quesa.

/// Reads the values of an object's data in order, whichever encoding it is in: big- or little-endian binary, or
/// a text metafile's tokens. An object's reader asks for what it expects, as Quesa's read methods do.
struct MetafileDataReader {

    private let data: MetafileObjectData
    private var position = 0

    init(_ data: MetafileObjectData) {
        self.data = data
    }

    var isAtEnd: Bool {
        switch data {
        case .binary(let bytes, _): position >= bytes.count
        case .text(let tokens): position >= tokens.count
        }
    }

    // MARK: Numbers

    mutating func uint32() throws(SceneFormatError) -> UInt32 {
        switch data {
        case .binary(let bytes, let order):
            return try fixedWidth(bytes, order, 4)
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
        case .binary(let bytes, let order): UInt16(try fixedWidth(bytes, order, 2))
        case .text: UInt16(truncatingIfNeeded: try integer())
        }
    }

    mutating func uint8() throws(SceneFormatError) -> UInt8 {
        switch data {
        case .binary(let bytes, let order): UInt8(try fixedWidth(bytes, order, 1))
        case .text: UInt8(truncatingIfNeeded: try integer())
        }
    }

    mutating func int8() throws(SceneFormatError) -> Int8 {
        Int8(bitPattern: try uint8())
    }

    mutating func uint64() throws(SceneFormatError) -> UInt64 {
        switch data {
        case .binary(let bytes, let order):
            let high = UInt64(try fixedWidth(bytes, order, 4)), low = UInt64(try fixedWidth(bytes, order, 4))
            return order == .bigEndian ? high << 32 | low : low << 32 | high
        case .text:
            return UInt64(truncatingIfNeeded: try integer())
        }
    }

    mutating func float32() throws(SceneFormatError) -> Float {
        switch data {
        case .binary(let bytes, let order):
            return Float(bitPattern: try fixedWidth(bytes, order, 4))
        case .text(let tokens):
            let token = try nextToken(tokens)
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
        case .binary(let bytes, _):
            guard let end = bytes[position...].firstIndex(of: 0) else { throw .unexpectedEndOfData(offset: bytes.count) }
            let string = String(decoding: bytes[position..<end], as: UTF8.self)
            position = min(Self.padded(end + 1), bytes.count)
            return string
        case .text(let tokens):
            let token = try nextToken(tokens)
            guard token.count >= 2, token.first == "\"", token.last == "\"" else { return token }
            return Self.unescape(token.dropFirst().dropLast())
        }
    }

    /// Raw bytes: `count` of them padded to four in binary, hexadecimal runs (`0x…`) in text.
    mutating func rawBytes(_ count: Int) throws(SceneFormatError) -> [UInt8] {
        switch data {
        case .binary(let bytes, _):
            guard position + count <= bytes.count else { throw .unexpectedEndOfData(offset: bytes.count) }
            let raw = Array(bytes[position ..< position + count])
            position = min(Self.padded(position + count), bytes.count)
            return raw
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

    private mutating func fixedWidth(_ bytes: [UInt8], _ order: Metafile3D.ByteOrder, _ width: Int) throws(SceneFormatError) -> UInt32 {
        guard position + width <= bytes.count else { throw .unexpectedEndOfData(offset: position) }
        var value: UInt32 = 0
        for i in 0..<width {
            let byte = UInt32(bytes[position + (order == .bigEndian ? i : width - 1 - i)])
            value = value << 8 | byte
        }
        position += width
        return value
    }

    private mutating func nextToken(_ tokens: [String]) throws(SceneFormatError) -> String {
        guard position < tokens.count else { throw .unexpectedEndOfData(offset: position) }
        defer { position += 1 }
        return tokens[position]
    }

    private mutating func integer() throws(SceneFormatError) -> Int64 {
        guard case .text(let tokens) = data else { preconditionFailure("Text only") }
        let token = try nextToken(tokens)
        if let value = Self.parseInteger(token) { return value }
        // A float where an integer belongs, as some writers put them.
        if let value = Float(token), value.isFinite { return Int64(value) }
        throw .malformed("\"\(token)\" is not an integer", offset: nil)
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
