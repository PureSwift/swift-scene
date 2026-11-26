// Ported from Quesa's binary 3DMF reader (E3FFR_3DMF_Bin.cpp).
// Copyright (c) 1999-2021, Quesa Developers. All rights reserved.
// Licensed under the BSD 3-Clause License; see LICENSE-Quesa.

/// Reads a binary metafile into objects.
///
/// The file is a 24-byte header, then objects, each a four-character type, a 32-bit size and that many bytes
/// of data. Containers (`cntr`) hold an object followed by its children; groups run from a `bgng` container to
/// the matching `endg`; references (`rfrn`) name an object elsewhere in the file through the table of contents
/// (`toc `); `type` objects give names to custom types' negative codes. Big-endian files start `3DMF`;
/// little-endian ones `FMD3`.
struct BinaryMetafileParser {

    private let bytes: [UInt8]
    private var order = Metafile3D.ByteOrder.bigEndian
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

    mutating func parse() throws(SceneFormatError) -> Metafile3D {
        guard bytes.count >= 24 else { throw .invalidHeader("A binary 3DMF file is at least 24 bytes") }
        switch Array(bytes[0..<4]) {
        case Array("3DMF".utf8): order = .bigEndian
        case Array("FMD3".utf8): order = .littleEndian
        default: throw .invalidHeader("Not a 3DMF file")
        }
        var header = reader(4..<24)
        let headerSize = try header.uint32()
        guard headerSize == 16 else { throw .invalidHeader("A 3DMF header is 16 bytes, not \(headerSize)") }
        let version = try header.uint32()
        let flags = try header.uint32()
        let tocLocation = try header.uint64()
        let mode = Metafile3D.Mode(rawValue: flags & 0x3) ?? .normal

        var end = bytes.count
        if tocLocation != 0 {
            guard tocLocation < UInt64(bytes.count) else { throw .malformed("The table of contents is past the end", offset: 16) }
            // The table of contents is usually last; objects stop before it.
            if let tocEnd = try readTableOfContents(at: Int(tocLocation)), tocEnd >= bytes.count - 8 {
                end = Int(tocLocation)
            }
        }
        var position = 24
        let objects = try readSequence(&position, end: end, depth: 0, inGroup: false)
        return Metafile3D(
            encoding: .binary(order),
            majorVersion: UInt16(version >> 16),
            minorVersion: UInt16(version & 0xFFFF),
            mode: mode,
            objects: objects
        )
    }

    // MARK: Table of contents

    /// Reads a table of contents and any that follow it; gives where the first ends.
    private mutating func readTableOfContents(at location: Int) throws(SceneFormatError) -> Int? {
        var location = location
        var firstEnd: Int?
        var visited: Set<Int> = []
        while location != 0, visited.insert(location).inserted {
            let (type, size, dataStart) = try objectHeader(at: location)
            guard type == MetafileObjectType.tableOfContents.code else {
                throw .malformed("Expected a table of contents", offset: location)
            }
            var toc = reader(dataStart ..< dataStart + size)
            let next = try toc.uint64()
            _ = try toc.int32() // Reference seed.
            _ = try toc.int32() // Type seed.
            let entryType = try toc.uint32()
            let entrySize = try toc.uint32()
            let count = try toc.uint32()
            guard (entryType == 0 && entrySize == 12) || (entryType == 1 && entrySize == 16) else {
                throw .malformed("Unknown table of contents entries", offset: location)
            }
            for _ in 0..<count {
                let id = try toc.uint32()
                let objectLocation = try toc.uint64()
                if entryType == 1 { _ = try toc.uint32() } // The object's type.
                referenceLocations[id] = Int(objectLocation)
            }
            if firstEnd == nil { firstEnd = dataStart + size }
            location = Int(next)
        }
        return firstEnd
    }

    // MARK: Objects

    /// Reads objects from `position` to `end`; in a group, up to and past its `endg`.
    private mutating func readSequence(_ position: inout Int, end: Int, depth: Int, inGroup: Bool) throws(SceneFormatError) -> [MetafileObject] {
        guard depth < maximumDepth else { throw .malformed("Objects nest too deeply", offset: position) }
        var objects: [MetafileObject] = []
        while position + 8 <= end {
            let start = position
            let (code, size, dataStart) = try objectHeader(at: position)
            position = dataStart + size
            guard position <= end else { throw .unexpectedEndOfData(offset: start) }

            switch code {
            case MetafileObjectType.endGroup.code:
                if inGroup { return objects }
            case MetafileObjectType.tableOfContents.code:
                continue
            case MetafileObjectType.type.code:
                var data = reader(dataStart ..< position)
                let id = try data.int32()
                customTypes[id] = try data.string()
            case MetafileObjectType.beginGroup.code:
                if let group = try readGroup(dataStart: dataStart, after: &position, end: end, depth: depth) {
                    objects.append(group)
                }
            default:
                if let object = try readObject(code: code, at: start, dataStart: dataStart, end: position, depth: depth) {
                    objects.append(object)
                }
            }
        }
        return objects
    }

    /// Reads a group: its `bgng` container holds the group and its state, and what follows, up to the matching
    /// `endg`, is its contents.
    private mutating func readGroup(dataStart: Int, after position: inout Int, end: Int, depth: Int) throws(SceneFormatError) -> MetafileObject? {
        var inner = dataStart
        var parts = try readSequence(&inner, end: position, depth: depth + 1, inGroup: false)
        let contents = try readSequence(&position, end: end, depth: depth + 1, inGroup: true)
        guard !parts.isEmpty else { return nil }
        var group = parts.removeFirst()
        group.children += parts + contents
        return group
    }

    /// Reads one object that isn't structure: a container's contents, a reference's object, or a plain object.
    private mutating func readObject(code: UInt32, at start: Int, dataStart: Int, end: Int, depth: Int) throws(SceneFormatError) -> MetafileObject? {
        switch code {
        case MetafileObjectType.container.code:
            var inner = dataStart
            var parts = try readSequence(&inner, end: end, depth: depth + 1, inGroup: false)
            guard !parts.isEmpty else { return nil }
            var root = parts.removeFirst()
            root.children += parts
            return root
        case MetafileObjectType.reference.code:
            var data = reader(dataStart ..< end)
            let id = try data.uint32()
            // Reference 0 is a placeholder for nothing.
            guard id != 0 else { return nil }
            guard let location = referenceLocations[id] else {
                throw .malformed("Reference \(id) isn't in the table of contents", offset: start)
            }
            return try readReferenced(at: location, depth: depth)
        default:
            let type: MetafileObjectType = Int32(bitPattern: code) < 0
                ? customTypes[Int32(bitPattern: code)].map { MetafileObjectType.custom($0) } ?? .code(code)
                : .code(code)
            return MetafileObject(type: type, data: .binary(Array(bytes[dataStart ..< end]), order))
        }
    }

    private mutating func readReferenced(at location: Int, depth: Int) throws(SceneFormatError) -> MetafileObject? {
        if let known = referenced[location] { return known }
        guard resolving.insert(location).inserted else {
            throw .malformed("A reference leads back to itself", offset: location)
        }
        defer { resolving.remove(location) }
        let (code, size, dataStart) = try objectHeader(at: location)
        guard dataStart + size <= bytes.count else { throw .unexpectedEndOfData(offset: location) }
        let object: MetafileObject?
        if code == MetafileObjectType.beginGroup.code {
            // A shared group: its contents follow it where it is.
            var position = dataStart + size
            object = try readGroup(dataStart: dataStart, after: &position, end: bytes.count, depth: depth + 1)
        } else {
            object = try readObject(code: code, at: location, dataStart: dataStart, end: dataStart + size, depth: depth + 1)
        }
        referenced[location] = object
        return object
    }

    // MARK: Helpers

    private func objectHeader(at location: Int) throws(SceneFormatError) -> (code: UInt32, size: Int, dataStart: Int) {
        guard location >= 0, location + 8 <= bytes.count else { throw .unexpectedEndOfData(offset: location) }
        var header = reader(location ..< location + 8)
        let code = try header.uint32()
        let size = Int(try header.uint32())
        guard location + 8 + size <= bytes.count else { throw .unexpectedEndOfData(offset: location) }
        return (code, size, location + 8)
    }

    private func reader(_ range: Range<Int>) -> MetafileDataReader {
        MetafileDataReader(.binary(Array(bytes[range]), order))
    }
}
