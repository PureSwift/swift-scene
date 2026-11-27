import SceneFormats

/// An in-memory USDZ package. Entry data is stored without compression and begins on a
/// 64-byte boundary. This container does not parse USD layers or resolve composition arcs.
public struct USDZArchive: Sendable {
    public struct Entry: Hashable, Sendable {
        public let path: String
        /// A view into the archive's bytes. Use startIndex rather than assuming a zero-based slice.
        public let data: ArraySlice<UInt8>

        public init(path: String, data: [UInt8]) {
            self.path = path
            self.data = data[...]
        }

        fileprivate init(path: String, data: ArraySlice<UInt8>) {
            self.path = path
            self.data = data
        }
    }

    /// Physical file order, which determines the default layer independently of directory order.
    public let entries: [Entry]
    private let indices: [String: Int]

    /// The first file, only when it is a native USD layer. Asset-only packages have no default layer.
    public var defaultLayer: Entry? {
        guard let first = entries.first, ["usd", "usda", "usdc"].contains(Self.extensionOf(first.path)) else { return nil }
        return first
    }

    public subscript(path: String) -> Entry? { indices[path].map { entries[$0] } }

    /// Constructs a package in the given file order, without reordering its default layer.
    public init(entries: [Entry]) throws(SceneFormatError) {
        guard entries.count < Int(UInt16.max) else { throw .unsupported("USDZ ZIP64 entry counts") }
        var indices: [String: Int] = [:]
        for (index, entry) in entries.enumerated() {
            try Self.validatePath(entry.path)
            guard indices.updateValue(index, forKey: entry.path) == nil else {
                throw .malformed("Duplicate USDZ path: \(entry.path)", offset: nil)
            }
            guard entry.data.count < Int(UInt32.max) else { throw .unsupported("USDZ ZIP64 entry sizes") }
        }
        self.entries = entries
        self.indices = indices
    }

    /// Reads classic ZIP records, validates headers, alignment and CRC-32, and retains slices
    /// of the input storage. Compressed/encrypted, split, ZIP64 and data-descriptor archives are rejected.
    public init(_ bytes: [UInt8]) throws(SceneFormatError) {
        let reader = USDZReader(bytes: bytes)
        let records = try reader.records()
        self.entries = records.map { Entry(path: $0.path, data: bytes[$0.dataRange]) }
        self.indices = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.element.path, $0.offset) })
    }

    /// Produces deterministic ZIP bytes with UTF-8 names and 64-byte-aligned uncompressed data.
    /// Timestamps, comments, and unrecognized extra fields from an input archive are not retained.
    public func encoded() throws(SceneFormatError) -> [UInt8] {
        var output = USDZWriter()
        var directory = USDZWriter()
        for entry in entries {
            let name = Array(entry.path.utf8)
            let offset = output.bytes.count
            let minimum = offset + 30 + name.count
            var padding = (64 - minimum % 64) % 64
            // Padding is a well-formed ZIP extra field, including its four-byte header.
            if padding > 0 && padding < 4 { padding += 64 }
            guard offset < Int(UInt32.max), minimum + padding + entry.data.count < Int(UInt32.max) else {
                throw .unsupported("USDZ ZIP64 archive sizes")
            }
            let crc = USDZCRC32.checksum(entry.data)
            output.word(0x04034b50)
            output.short(20); output.short(0x0800); output.short(0)
            output.short(0); output.short(0x21) // 1980-01-01, fixed for reproducible output.
            output.word(crc); output.word(UInt32(entry.data.count)); output.word(UInt32(entry.data.count))
            output.short(UInt16(name.count)); output.short(UInt16(padding))
            output.bytes += name
            if padding > 0 {
                output.short(0x1986); output.short(UInt16(padding - 4))
                output.bytes += repeatElement(0, count: padding - 4)
            }
            output.bytes += entry.data

            directory.word(0x02014b50)
            directory.short(20); directory.short(20); directory.short(0x0800); directory.short(0)
            directory.short(0); directory.short(0x21)
            directory.word(crc); directory.word(UInt32(entry.data.count)); directory.word(UInt32(entry.data.count))
            directory.short(UInt16(name.count)); directory.short(0); directory.short(0)
            directory.short(0); directory.short(0); directory.word(0); directory.word(UInt32(offset))
            directory.bytes += name
        }
        let directoryOffset = output.bytes.count
        guard directoryOffset + directory.bytes.count + 22 < Int(UInt32.max) else {
            throw .unsupported("USDZ ZIP64 archive sizes")
        }
        output.bytes += directory.bytes
        output.word(0x06054b50); output.short(0); output.short(0)
        output.short(UInt16(entries.count)); output.short(UInt16(entries.count))
        output.word(UInt32(directory.bytes.count)); output.word(UInt32(directoryOffset)); output.short(0)
        return output.bytes
    }

    fileprivate static func extensionOf(_ path: String) -> String {
        String(path.split(separator: "/").last?.split(separator: ".").last ?? "")
    }

    fileprivate static func validatePath(_ path: String) throws(SceneFormatError) {
        let bytes = Array(path.utf8)
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !bytes.isEmpty, bytes.count <= Int(UInt16.max),
              !bytes.contains(where: { $0 < 32 || $0 == 127 }),
              !path.contains("\\"), !path.contains(":"), !path.contains("["), !path.contains("]"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw .malformed("USDZ requires canonical relative file paths", offset: nil)
        }
        let supported = ["usd", "usda", "usdc", "usdz", "png", "jpg", "jpeg", "jpe", "exr", "avif", "m4a", "mp3", "wav"]
        guard parts.last?.contains(".") == true, supported.contains(extensionOf(path)) else {
            throw .unsupported("USDZ member file type: \(path)")
        }
    }
}

private struct USDZReader {
    let bytes: [UInt8]
    struct Record {
        let path: String
        let localOffset: Int
        let dataRange: Range<Int>
    }

    func records() throws(SceneFormatError) -> [Record] {
        guard bytes.count >= 22 else { throw .invalidHeader("Truncated USDZ ZIP footer") }
        // The ZIP comment may be 65535 bytes. A signature inside it must also end at EOF.
        var footer: Int?
        for offset in stride(from: bytes.count - 22, through: max(0, bytes.count - 22 - 65535), by: -1) {
            if try word(offset) == 0x06054b50, offset + 22 + Int(try short(offset + 20)) == bytes.count {
                footer = offset
                break
            }
        }
        guard let footer else { throw .invalidHeader("Missing USDZ ZIP footer") }
        let count = Int(try short(footer + 10))
        let directorySize = Int(try word(footer + 12))
        let directoryOffset = Int(try word(footer + 16))
        guard count != Int(UInt16.max), directorySize != Int(UInt32.max), directoryOffset != Int(UInt32.max) else {
            throw .unsupported("USDZ ZIP64 archives")
        }
        guard try short(footer + 4) == 0, try short(footer + 6) == 0, try Int(short(footer + 8)) == count else {
            throw .unsupported("USDZ split ZIP archives")
        }
        guard directoryOffset <= footer, directorySize == footer - directoryOffset,
              count <= directorySize / 46 else {
            throw .malformed("Invalid USDZ central directory bounds", offset: footer)
        }
        var records: [Record] = []
        var paths: Set<String> = []
        var cursor = directoryOffset
        for _ in 0..<count {
            try require(cursor, count: 46, before: footer)
            guard try word(cursor) == 0x02014b50 else { throw .invalidHeader("Invalid USDZ central directory signature") }
            let flags = try short(cursor + 8)
            let method = try short(cursor + 10)
            let crc = try word(cursor + 16)
            let size = Int(try word(cursor + 24))
            let local = Int(try word(cursor + 42))
            let nameLength = Int(try short(cursor + 28))
            let extraLength = Int(try short(cursor + 30))
            let commentLength = Int(try short(cursor + 32))
            guard size != Int(UInt32.max), local != Int(UInt32.max) else { throw .unsupported("USDZ ZIP64 entries") }
            guard try short(cursor + 6) <= 20, flags & ~0x0800 == 0, method == 0 else {
                throw .unsupported("USDZ requires stored, unencrypted ZIP entries without data descriptors")
            }
            guard try short(cursor + 34) == 0 else { throw .unsupported("USDZ split ZIP entries") }
            let attributes = try word(cursor + 38)
            let unixType = (attributes >> 16) & 0xf000
            guard attributes & 0x10 == 0, unixType == 0 || unixType == 0x8000 else {
                throw .unsupported("USDZ directory, symlink or special-file entries")
            }
            guard try Int(word(cursor + 20)) == size else { throw .malformed("USDZ stored sizes disagree", offset: cursor) }
            try require(cursor + 46, count: nameLength + extraLength + commentLength, before: footer)
            let nameBytes = bytes[cursor + 46..<cursor + 46 + nameLength]
            guard flags & 0x0800 != 0 || nameBytes.allSatisfy({ $0 < 128 }) else {
                throw .unsupported("Non-UTF-8 USDZ filenames")
            }
            guard let path = String(validating: nameBytes, as: UTF8.self) else { throw .malformed("Invalid UTF-8 USDZ path", offset: cursor) }
            try USDZArchive.validatePath(path)
            guard paths.insert(path).inserted else { throw .malformed("Duplicate USDZ path: \(path)", offset: cursor) }
            try extraFields(cursor + 46 + nameLength, count: extraLength)
            try require(local, count: 30, before: directoryOffset)
            guard try word(local) == 0x04034b50 else { throw .invalidHeader("Invalid USDZ local signature") }
            let localNameLength = Int(try short(local + 26))
            let localExtraLength = Int(try short(local + 28))
            let dataStart = local + 30 + localNameLength + localExtraLength
            try require(local + 30, count: localNameLength + localExtraLength, before: directoryOffset)
            try require(dataStart, count: size, before: directoryOffset)
            guard dataStart % 64 == 0 else { throw .malformed("USDZ member is not aligned to 64 bytes", offset: dataStart) }
            guard try short(local + 4) == short(cursor + 6), try short(local + 6) == flags,
                  try short(local + 8) == method, try word(local + 14) == crc,
                  try Int(word(local + 18)) == size, try Int(word(local + 22)) == size,
                  bytes[local + 30..<local + 30 + localNameLength].elementsEqual(nameBytes) else {
                throw .malformed("USDZ local and central headers disagree", offset: local)
            }
            try extraFields(local + 30 + localNameLength, count: localExtraLength)
            let range = dataStart..<dataStart + size
            records.append(Record(path: path, localOffset: local, dataRange: range))
            // CRC is checked after overlap validation so aliases cannot cause repeated scans.
            cursor += 46 + nameLength + extraLength + commentLength
        }
        guard cursor == footer else { throw .malformed("Unexpected USDZ directory records", offset: cursor) }
        records.sort { $0.localOffset < $1.localOffset }
        var previousEnd = 0
        for record in records {
            guard record.localOffset >= previousEnd else { throw .malformed("Overlapping USDZ members", offset: record.localOffset) }
            previousEnd = record.dataRange.upperBound
        }
        for record in records {
            guard USDZCRC32.checksum(bytes[record.dataRange]) == (try word(record.localOffset + 14)) else {
                throw .malformed("USDZ CRC-32 mismatch: \(record.path)", offset: record.dataRange.lowerBound)
            }
        }
        guard (records.first?.localOffset ?? directoryOffset) == 0 else { throw .unsupported("USDZ ZIP preambles") }
        return records
    }

    func extraFields(_ start: Int, count: Int) throws(SceneFormatError) {
        var cursor = start
        let end = start + count
        while cursor < end {
            try require(cursor, count: 4, before: end)
            let tag = try short(cursor)
            let size = Int(try short(cursor + 2))
            guard tag != 0x0001 else { throw .unsupported("USDZ ZIP64 extra fields") }
            try require(cursor + 4, count: size, before: end)
            cursor += 4 + size
        }
    }

    func require(_ offset: Int, count: Int, before end: Int) throws(SceneFormatError) {
        guard offset >= 0, count >= 0, end <= bytes.count, offset <= end, count <= end - offset else {
            throw .unexpectedEndOfData(offset: offset)
        }
    }

    func short(_ offset: Int) throws(SceneFormatError) -> UInt16 {
        try require(offset, count: 2, before: bytes.count)
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    func word(_ offset: Int) throws(SceneFormatError) -> UInt32 {
        try require(offset, count: 4, before: bytes.count)
        return (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) }
    }
}

private struct USDZWriter {
    var bytes: [UInt8] = []
    mutating func short(_ value: UInt16) {
        bytes += [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]
    }
    mutating func word(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }
}

private enum USDZCRC32 {
    static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 0 ? value >> 1 : (value >> 1) ^ 0xedb88320 }
        return value
    }
    static func checksum(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in bytes { crc = table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) }
        return crc ^ 0xffffffff
    }
}
