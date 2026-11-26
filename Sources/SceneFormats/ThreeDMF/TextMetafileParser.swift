// Ported from Quesa's text 3DMF reader (E3FFR_3DMF_Text.cpp).
// Copyright (c) 1999-2021, Quesa Developers. All rights reserved.
// Licensed under the BSD 3-Clause License; see LICENSE-Quesa.

/// Reads a text metafile into objects.
///
/// The file is `3DMetafile ( major minor mode tocLabel> )`, then objects: `ClassName ( values… )`, nesting inside
/// `Container ( … )` and `BeginGroup ( … ) … EndGroup ( )` as a binary file's do. `#` starts a comment to the end of
/// the line. `label:` names the object after it; `label>` refers to one, as the table of contents does to map
/// `Reference ( n )` to the object it means.
struct TextMetafileParser {

    private var tokens: [String] = []
    private var position = 0
    /// Objects by label, as written (references inside unresolved).
    private var labeled: [String: MetafileObject] = [:]
    /// Labels by reference number, from the tables of contents.
    private var referenceLabels: [UInt32: String] = [:]

    private let maximumDepth = 256

    init(_ bytes: [UInt8]) {
        self.tokens = Self.tokenize(bytes)
    }

    mutating func parse() throws(SceneFormatError) -> Metafile3D {
        guard position < tokens.count, tokens[position] == "3DMetafile" else { throw .invalidHeader("Not a text 3DMF file") }
        position += 1
        let header = try values()
        var reader = MetafileDataReader(.text(header))
        let major = try reader.uint16()
        let minor = try reader.uint16()
        let mode = try reader.enumerated(["normal": 0, "stream": 1, "database": 2])

        let objects = try sequence(depth: 0, inGroup: false)
        var resolving: Set<String> = []
        var resolved: [String: MetafileObject] = [:]
        var result: [MetafileObject] = []
        for object in objects {
            if let object = try resolve(object, resolving: &resolving, resolved: &resolved) {
                result.append(object)
            }
        }
        return Metafile3D(
            encoding: .text,
            majorVersion: major,
            minorVersion: minor,
            mode: Metafile3D.Mode(rawValue: mode) ?? .normal,
            objects: result
        )
    }

    // MARK: Objects

    /// Reads objects to the end of the file, the end of the enclosing parentheses, or, in a group, its `EndGroup`.
    private mutating func sequence(depth: Int, inGroup: Bool) throws(SceneFormatError) -> [MetafileObject] {
        guard depth < maximumDepth else { throw .malformed("Objects nest too deeply", offset: position) }
        var objects: [MetafileObject] = []
        while position < tokens.count, tokens[position] != ")" {
            guard let object = try object(depth: depth) else { continue }
            switch object.type {
            case .endGroup:
                if inGroup { return objects }
            case .beginGroup:
                // Its parentheses hold the group and its state; what follows, up to `EndGroup`, is its contents.
                var parts = object.children
                let contents = try sequence(depth: depth + 1, inGroup: true)
                guard !parts.isEmpty else { break }
                var group = parts.removeFirst()
                group.children += parts + contents
                group.label = group.label ?? object.label
                if let label = group.label { labeled[label] = group }
                objects.append(group)
            case .tableOfContents, .type:
                break
            default:
                objects.append(object)
            }
        }
        return objects
    }

    /// Reads `label: ClassName ( … )`; nil for what isn't an object.
    private mutating func object(depth: Int) throws(SceneFormatError) -> MetafileObject? {
        var label: String?
        if tokens[position].hasSuffix(":") {
            label = String(tokens[position].dropLast())
            position += 1
        }
        guard position < tokens.count else { throw .unexpectedEndOfData(offset: position) }
        // A custom class's name may have spaces: `Apple Computer, Inc.:NameElement ( )`.
        var nameParts: [String] = []
        while position < tokens.count, tokens[position] != "(", tokens[position] != ")", nameParts.count < 8 {
            nameParts.append(tokens[position])
            position += 1
        }
        let className = nameParts.joined(separator: " ")
        guard !nameParts.isEmpty, position < tokens.count, tokens[position] == "(" else {
            throw .malformed("Expected \"(\" after \(className)", offset: position)
        }
        position += 1
        let type = MetafileObjectType(className: className)

        var data: [String] = []
        var nested: [MetafileObject] = []
        if type == .container || type == .beginGroup {
            nested = try sequence(depth: depth + 1, inGroup: false)
        } else {
            // Values, and objects a custom or attribute-carrying object holds.
            while position < tokens.count, tokens[position] != ")" {
                if isObjectStart(position) {
                    if let child = try object(depth: depth + 1) { nested.append(child) }
                } else {
                    data.append(tokens[position])
                    position += 1
                }
            }
        }
        // The end of the file closes what's open, as Quesa reads files that leave a parenthesis unclosed.
        if position < tokens.count { position += 1 } // ")"

        var object: MetafileObject
        switch type {
        case .container:
            guard !nested.isEmpty else { return nil }
            object = nested.removeFirst()
            object.children += nested
            object.label = label ?? object.label
        case .beginGroup:
            object = MetafileObject(type: .beginGroup, data: .empty, children: nested, label: label)
            return object
        case .tableOfContents:
            readTableOfContents(data)
            return MetafileObject(type: .tableOfContents, data: .empty)
        default:
            object = MetafileObject(type: type, data: .text(data), children: nested, label: label)
        }
        if let label { labeled[label] = object }
        return object
    }

    private func isObjectStart(_ index: Int) -> Bool {
        if tokens[index].hasSuffix(":") { return true }
        return index + 1 < tokens.count && tokens[index + 1] == "(" && !tokens[index].hasPrefix("\"")
    }

    /// The values in the next parentheses.
    private mutating func values() throws(SceneFormatError) -> [String] {
        guard position < tokens.count, tokens[position] == "(" else { throw .malformed("Expected \"(\"", offset: position) }
        position += 1
        var values: [String] = []
        while position < tokens.count, tokens[position] != ")" {
            values.append(tokens[position])
            position += 1
        }
        guard position < tokens.count else { throw .unexpectedEndOfData(offset: position) }
        position += 1
        return values
    }

    // MARK: References

    /// Notes a table of contents' entries: `nextTOC> refSeed typeSeed entryType entrySize count`, then for each,
    /// `id label>` and, for entry type 1, the object's class.
    private mutating func readTableOfContents(_ data: [String]) {
        guard data.count >= 6, let entryType = Int(data[3]), let count = Int(data[5]) else { return }
        var index = 6
        for _ in 0..<count {
            guard index + 1 < data.count, let id = UInt32(data[index]) else { return }
            let label = data[index + 1].hasSuffix(">") ? String(data[index + 1].dropLast()) : data[index + 1]
            referenceLabels[id] = label
            index += entryType == 1 ? 3 : 2
        }
    }

    /// The object with its references replaced by what they refer to; nil for a reference to nothing.
    private func resolve(
        _ object: MetafileObject,
        resolving: inout Set<String>,
        resolved: inout [String: MetafileObject]
    ) throws(SceneFormatError) -> MetafileObject? {
        if object.type == .reference {
            var reader = object.reader()
            let id = try reader.uint32()
            guard id != 0 else { return nil }
            guard let label = referenceLabels[id], let target = labeled[label] else {
                throw .malformed("Reference \(id) isn't in the table of contents", offset: nil)
            }
            if let known = resolved[label] { return known }
            guard resolving.insert(label).inserted else { throw .malformed("A reference leads back to itself", offset: nil) }
            defer { resolving.remove(label) }
            let result = try resolve(target, resolving: &resolving, resolved: &resolved)
            resolved[label] = result
            return result
        }
        var copy = object
        var children: [MetafileObject] = []
        children.reserveCapacity(object.children.count)
        for child in object.children {
            if let child = try resolve(child, resolving: &resolving, resolved: &resolved) {
                children.append(child)
            }
        }
        copy.children = children
        return copy
    }

    // MARK: Tokens

    /// Splits the text into parentheses, quoted strings, `|` and words, without comments. Classic Mac files end
    /// lines with carriage returns.
    static func tokenize(_ bytes: [UInt8]) -> [String] {
        var tokens: [String] = []
        var index = 0
        let count = bytes.count
        func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0C || b == 0 }
        while index < count {
            let byte = bytes[index]
            if isSpace(byte) {
                index += 1
            } else if byte == UInt8(ascii: "#") {
                while index < count, bytes[index] != 0x0A, bytes[index] != 0x0D { index += 1 }
            } else if byte == UInt8(ascii: "(") || byte == UInt8(ascii: ")") || byte == UInt8(ascii: "|") {
                tokens.append(String(UnicodeScalar(byte)))
                index += 1
            } else if byte == UInt8(ascii: "\"") {
                let start = index
                index += 1
                while index < count, bytes[index] != UInt8(ascii: "\"") {
                    index += bytes[index] == UInt8(ascii: "\\") ? 2 : 1
                }
                index = min(index + 1, count)
                tokens.append(Self.decode(bytes[start..<index]))
            } else {
                let start = index
                while index < count, !isSpace(bytes[index]),
                      ![UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "#"), UInt8(ascii: "\""), UInt8(ascii: "|")].contains(bytes[index]) {
                    index += 1
                }
                tokens.append(Self.decode(bytes[start..<index]))
            }
        }
        return tokens
    }

    /// Text as UTF-8; what isn't (Mac Roman, in older files) reads as replacement characters.
    private static func decode(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes, as: UTF8.self)
    }
}
