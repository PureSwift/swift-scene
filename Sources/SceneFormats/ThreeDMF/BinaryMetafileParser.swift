// Ported from Quesa's binary 3DMF reader (E3FFR_3DMF_Bin.cpp).
// Copyright (c) 1999-2021, Quesa Developers. All rights reserved.
// Licensed under the BSD 3-Clause License; see LICENSE-Quesa.

import BinaryParsing

/// Reads a binary metafile into objects, with swift-binary-parsing.
///
/// The file is a 24-byte header, then objects, each a four-character type, a 32-bit size and that many bytes
/// of data. Containers (`cntr`) hold an object followed by its children; groups run from a `bgng` container to
/// the matching `endg`; references (`rfrn`) name an object elsewhere in the file through the table of contents
/// (`toc `); `type` objects give names to custom types' negative codes. Big-endian files start `3DMF`;
/// little-endian ones `FMD3`.
///
/// Every read is bounds-checked by the parser span, so a size or offset that points outside the file is an error
/// rather than a crash. Objects keep a range of the file for their data rather than a copy.
struct BinaryMetafileParser {

    private let bytes: [UInt8]
    private var endianness = Endianness.big
    /// Where each reference's object is, by reference number.
    private var referenceLocations: [UInt32: Int] = [:]
    /// Objects read from where references point, by location.
    private var referenced: [Int: MetafileObject] = [:]
    /// References being read, to stop one that leads back to itself.
    private var resolving: Set<Int> = []
    /// Custom types' names, by code.
    private var customTypes: [Int32: String] = [:]

    /// How deep containers may nest before the file is taken as corrupt.
    private let maximumDepth = 256

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    private var byteOrder: Metafile3D.ByteOrder { endianness.isBigEndian ? .bigEndian : .littleEndian }

    mutating func parse() throws(SceneFormatError) -> Metafile3D {
        guard bytes.count >= 24 else { throw .invalidHeader("A binary 3DMF file is at least 24 bytes") }
        switch Array(bytes[0..<4]) {
        case Array("3DMF".utf8): endianness = .big
        case Array("FMD3".utf8): endianness = .little
        default: throw .invalidHeader("Not a 3DMF file")
        }
        do {
            return try bytes.withParserSpan { (file: inout ParserSpan) throws -> Metafile3D in
                try file.seek(toRelativeOffset: 4)
                let headerSize = try UInt32(parsing: &file, endianness: endianness)
                guard headerSize == 16 else { throw SceneFormatError.invalidHeader("A 3DMF header is 16 bytes, not \(headerSize)") }
                let version = try UInt32(parsing: &file, endianness: endianness)
                let flags = try UInt32(parsing: &file, endianness: endianness)
                let tocLocation = try UInt64(parsing: &file, endianness: endianness)
                let mode = Metafile3D.Mode(rawValue: flags & 0x3) ?? .normal

                // The objects run from the header to the end, or to the table of contents.
                var objects = try file.seeking(toAbsoluteOffset: 24)
                if tocLocation != 0 {
                    guard let location = Int(exactly: tocLocation), location < bytes.count else {
                        throw SceneFormatError.malformed("The table of contents is past the end", offset: 16)
                    }
                    // The table of contents is usually last; objects stop before it.
                    if let tocEnd = try readTableOfContents(at: location, in: file), tocEnd >= bytes.count - 8 {
                        objects = try objects.sliceSpan(byteCount: location - 24)
                    }
                }
                let parsed = try readSequence(&objects, file: file, depth: 0, inGroup: false)
                return Metafile3D(
                    encoding: .binary(byteOrder),
                    majorVersion: UInt16(version >> 16),
                    minorVersion: UInt16(version & 0xFFFF),
                    mode: mode,
                    objects: parsed
                )
            }
        } catch let error as SceneFormatError {
            throw error
        } catch let error as ParsingError {
            throw SceneFormatError(error)
        } catch {
            throw .malformed("\(error)", offset: nil)
        }
    }

    // MARK: Table of contents

    /// Reads a table of contents and any that follow it; gives where the first ends.
    private mutating func readTableOfContents(at location: Int, in file: borrowing ParserSpan) throws -> Int? {
        var location = location
        var firstEnd: Int?
        var visited: Set<Int> = []
        while location != 0, visited.insert(location).inserted {
            var toc = try file.seeking(toAbsoluteOffset: location)
            let type = try UInt32(parsing: &toc, endianness: endianness)
            guard type == MetafileObjectType.tableOfContents.code else {
                throw SceneFormatError.malformed("Expected a table of contents", offset: location)
            }
            let size = try Int(parsing: &toc, storedAs: UInt32.self, endianness: endianness)
            var entries = try toc.sliceSpan(byteCount: size)
            let next = try UInt64(parsing: &entries, endianness: endianness)
            _ = try Int32(parsing: &entries, endianness: endianness) // Reference seed.
            _ = try Int32(parsing: &entries, endianness: endianness) // Type seed.
            let entryType = try UInt32(parsing: &entries, endianness: endianness)
            let entrySize = try UInt32(parsing: &entries, endianness: endianness)
            let count = try UInt32(parsing: &entries, endianness: endianness)
            guard (entryType == 0 && entrySize == 12) || (entryType == 1 && entrySize == 16) else {
                throw SceneFormatError.malformed("Unknown table of contents entries", offset: location)
            }
            for _ in 0..<count {
                let id = try UInt32(parsing: &entries, endianness: endianness)
                let objectLocation = try UInt64(parsing: &entries, endianness: endianness)
                if entryType == 1 { _ = try UInt32(parsing: &entries, endianness: endianness) } // The object's type.
                if let objectLocation = Int(exactly: objectLocation) { referenceLocations[id] = objectLocation }
            }
            if firstEnd == nil { firstEnd = toc.startPosition }
            guard let following = Int(exactly: next) else { break }
            location = following
        }
        return firstEnd
    }

    // MARK: Objects

    /// Reads objects to the end of the span; in a group, up to and past its `endg`.
    private mutating func readSequence(_ input: inout ParserSpan, file: borrowing ParserSpan, depth: Int, inGroup: Bool) throws -> [MetafileObject] {
        guard depth < maximumDepth else { throw SceneFormatError.malformed("Objects nest too deeply", offset: input.startPosition) }
        var objects: [MetafileObject] = []
        while input.count >= 8 {
            let start = input.startPosition
            let code = try UInt32(parsing: &input, endianness: endianness)
            let size = try Int(parsing: &input, storedAs: UInt32.self, endianness: endianness)
            guard size <= input.count else { throw SceneFormatError.unexpectedEndOfData(offset: start) }

            switch code {
            case MetafileObjectType.endGroup.code:
                try input.seek(toRelativeOffset: size)
                if inGroup { return objects }
            case MetafileObjectType.tableOfContents.code:
                try input.seek(toRelativeOffset: size)
            case MetafileObjectType.type.code:
                var data = try input.sliceSpan(byteCount: size)
                let id = try Int32(parsing: &data, endianness: endianness)
                customTypes[id] = try Self.string(&data)
            case MetafileObjectType.beginGroup.code:
                var container = try input.sliceSpan(byteCount: size)
                if let group = try readGroup(&container, after: &input, file: file, depth: depth) {
                    objects.append(group)
                }
            default:
                if let object = try readObject(code: code, at: start, data: &input, size: size, file: file, depth: depth) {
                    objects.append(object)
                }
            }
        }
        return objects
    }

    /// Reads a group: its `bgng` container holds the group and its state, and what follows, up to the matching
    /// `endg`, is its contents.
    private mutating func readGroup(_ container: inout ParserSpan, after input: inout ParserSpan, file: borrowing ParserSpan, depth: Int) throws -> MetafileObject? {
        var parts = try readSequence(&container, file: file, depth: depth + 1, inGroup: false)
        let contents = try readSequence(&input, file: file, depth: depth + 1, inGroup: true)
        guard !parts.isEmpty else { return nil }
        var group = parts.removeFirst()
        group.children += parts + contents
        return group
    }

    /// Reads one object that isn't structure, `size` bytes of data from `input`: a container's contents, a
    /// reference's object, or a plain object.
    private mutating func readObject(code: UInt32, at start: Int, data input: inout ParserSpan, size: Int, file: borrowing ParserSpan, depth: Int) throws -> MetafileObject? {
        switch code {
        case MetafileObjectType.container.code:
            var inner = try input.sliceSpan(byteCount: size)
            var parts = try readSequence(&inner, file: file, depth: depth + 1, inGroup: false)
            guard !parts.isEmpty else { return nil }
            var root = parts.removeFirst()
            root.children += parts
            return root
        case MetafileObjectType.reference.code:
            var data = try input.sliceSpan(byteCount: size)
            let id = try UInt32(parsing: &data, endianness: endianness)
            // Reference 0 is a placeholder for nothing.
            guard id != 0 else { return nil }
            guard let location = referenceLocations[id] else {
                throw SceneFormatError.malformed("Reference \(id) isn't in the table of contents", offset: start)
            }
            return try readReferenced(at: location, file: file, depth: depth)
        default:
            let type: MetafileObjectType = Int32(bitPattern: code) < 0
                ? customTypes[Int32(bitPattern: code)].map { MetafileObjectType.custom($0) } ?? .code(code)
                : .code(code)
            let range = try input.sliceRange(byteCount: size)
            return MetafileObject(type: type, data: .binary(BinaryMetafileData(file: bytes, range: range, byteOrder: byteOrder)))
        }
    }

    private mutating func readReferenced(at location: Int, file: borrowing ParserSpan, depth: Int) throws -> MetafileObject? {
        if let known = referenced[location] { return known }
        guard resolving.insert(location).inserted else {
            throw SceneFormatError.malformed("A reference leads back to itself", offset: location)
        }
        defer { resolving.remove(location) }
        var input = try file.seeking(toAbsoluteOffset: location)
        let code = try UInt32(parsing: &input, endianness: endianness)
        let size = try Int(parsing: &input, storedAs: UInt32.self, endianness: endianness)
        guard size <= input.count else { throw SceneFormatError.unexpectedEndOfData(offset: location) }
        let object: MetafileObject?
        if code == MetafileObjectType.beginGroup.code {
            // A shared group: its contents follow it where it is.
            var container = try input.sliceSpan(byteCount: size)
            object = try readGroup(&container, after: &input, file: file, depth: depth + 1)
        } else {
            object = try readObject(code: code, at: location, data: &input, size: size, file: file, depth: depth + 1)
        }
        referenced[location] = object
        return object
    }

    /// A null-terminated string padded to four bytes, as a `type` object's name is.
    private static func string(_ input: inout ParserSpan) throws -> String {
        let start = input.startPosition
        var utf8: [UInt8] = []
        while true {
            let byte = try UInt8(parsing: &input)
            if byte == 0 { break }
            utf8.append(byte)
        }
        let consumed = input.startPosition - start
        let padding = min((consumed + 3) & ~3 - consumed, input.count)
        if padding > 0 { try input.seek(toRelativeOffset: padding) }
        return String(decoding: utf8, as: UTF8.self)
    }
}
