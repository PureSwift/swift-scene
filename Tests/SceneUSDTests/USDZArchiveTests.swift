import Foundation
import Testing
import SceneFormats
@testable import SceneUSD

@Suite struct USDZArchiveTests {
    private func sample() throws -> [UInt8] {
        try USDZArchive(entries: [
            .init(path: "root.usda", data: Array("#usda 1.0\n".utf8)),
            .init(path: "textures/é.png", data: [1, 2, 3, 4])
        ]).encoded()
    }
    private func word(_ bytes: [UInt8], _ offset: Int) -> Int {
        (0..<4).reduce(0) { $0 | Int(bytes[offset + $1]) << ($1 * 8) }
    }
    private func set(_ bytes: inout [UInt8], _ offset: Int, _ value: Int, width: Int = 4) {
        for i in 0..<width { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
    }

    @Test func readsIndependentPythonFixture() throws {
        let url = try #require(Bundle.module.url(forResource: "reference", withExtension: "usdz", subdirectory: "Fixtures"))
        let archive = try USDZArchive(Array(Data(contentsOf: url)))
        #expect(archive.entries.map(\.path) == ["root.usda", "textures/pixel.png"])
        #expect(archive.defaultLayer?.path == "root.usda")
        #expect(archive["textures/pixel.png"]?.data.prefix(8).elementsEqual([137, 80, 78, 71, 13, 10, 26, 10]) == true)
        let rebuilt = try USDZArchive(archive.encoded())
        #expect(rebuilt.entries == archive.entries)
    }

    @Test func roundTripsDeterministicallyWithAlignedUTF8Names() throws {
        let bytes = try sample()
        let archive = try USDZArchive(bytes)
        #expect(archive.entries.count == 2)
        #expect(archive["textures/é.png"]?.data.elementsEqual([1, 2, 3, 4]) == true)
        #expect(archive["missing.png"] == nil)
        #expect(archive.entries.allSatisfy { $0.data.startIndex % 64 == 0 })
        #expect(try archive.encoded() == bytes)
    }

    @Test func alignmentAcrossNameAndPayloadLengths() throws {
        let entries = (1...130).map { count in
            USDZArchive.Entry(path: String(repeating: "a", count: count) + ".usda", data: Array(repeating: UInt8(count), count: count))
        }
        let archive = try USDZArchive(USDZArchive(entries: entries).encoded())
        #expect(archive.entries == entries)
        #expect(archive.entries.allSatisfy { $0.data.startIndex % 64 == 0 })
    }

    @Test func defaultLayerUsesPhysicalOrderNotDirectoryOrder() throws {
        var bytes = try sample()
        let footer = bytes.count - 22
        let directory = word(bytes, footer + 16)
        let firstLength = 46 + "root.usda".utf8.count
        let first = Array(bytes[directory..<directory + firstLength])
        let second = Array(bytes[directory + firstLength..<footer])
        bytes.replaceSubrange(directory..<footer, with: second + first)
        #expect(try USDZArchive(bytes).defaultLayer?.path == "root.usda")
        let assets = try USDZArchive(entries: [.init(path: "pixel.png", data: [])])
        #expect(try USDZArchive(assets.encoded()).defaultLayer == nil)
        #expect(try USDZArchive(USDZArchive(entries: []).encoded()).entries.isEmpty)
    }

    @Test func rejectsUnsafeAndDuplicatePaths() throws {
        for path in ["/root.usda", "../root.usda", "a/../root.usda", "./root.usda", "a//root.usda",
                     "C:/root.usda", "a\\root.usda", "a\u{0}.usda", "folder/", "archive[member].usd", "file.exe"] {
            #expect(throws: SceneFormatError.self) { try USDZArchive(entries: [.init(path: path, data: [])]) }
        }
        #expect(throws: SceneFormatError.self) {
            try USDZArchive(entries: [.init(path: "root.usda", data: []), .init(path: "root.usda", data: [1])])
        }
    }

    @Test func rejectsTruncationAndCorruptData() throws {
        let bytes = try sample()
        for end in 0..<bytes.count {
            #expect(throws: SceneFormatError.self) { try USDZArchive(Array(bytes.prefix(end))) }
        }
        var corrupt = bytes
        corrupt[64] ^= 0xff
        #expect(throws: SceneFormatError.self) { try USDZArchive(corrupt) }
        corrupt = bytes
        corrupt[30] = UInt8(ascii: "x")
        #expect(throws: SceneFormatError.self) { try USDZArchive(corrupt) }
    }

    @Test func rejectsUnsupportedZIPFeaturesAndInvalidBounds() throws {
        let original = try sample()
        let footer = original.count - 22
        let directory = word(original, footer + 16)
        for (offset, value, width) in [(directory + 10, 8, 2), (directory + 8, 1, 2),
            (directory + 8, 8, 2), (directory + 24, Int(UInt32.max), 4),
            (directory + 42, directory, 4), (footer + 4, 1, 2), (footer + 12, 1, 4),
            (directory + 38, Int(0xa000 << 16), 4)] {
            var bytes = original
            set(&bytes, offset, value, width: width)
            #expect(throws: SceneFormatError.self) { try USDZArchive(bytes) }
        }
        var unaligned = original
        set(&unaligned, 28, 0, width: 2)
        #expect(throws: SceneFormatError.self) { try USDZArchive(unaligned) }
        var zip64 = original
        set(&zip64, 30 + "root.usda".utf8.count, 1, width: 2)
        #expect(throws: SceneFormatError.self) { try USDZArchive(zip64) }
    }

    @Test func acceptsZIPCommentAndRejectsTrailingGarbage() throws {
        var bytes = try sample()
        let comment = Array("A package comment".utf8)
        set(&bytes, bytes.count - 2, comment.count, width: 2)
        bytes += comment
        #expect(try USDZArchive(bytes).entries.count == 2)
        bytes.append(0)
        #expect(throws: SceneFormatError.self) { try USDZArchive(bytes) }
    }

    @Test func rejectsOverlappingMemberRangesBeforeChecksumming() throws {
        var bytes = try sample()
        let directory = word(bytes, bytes.count - 22 + 16)
        let secondDirectory = directory + 46 + "root.usda".utf8.count
        let secondLocal = word(bytes, secondDirectory + 42)
        let overlappingSize = directory - 64
        set(&bytes, 18, overlappingSize)
        set(&bytes, 22, overlappingSize)
        set(&bytes, directory + 20, overlappingSize)
        set(&bytes, directory + 24, overlappingSize)
        #expect(throws: SceneFormatError.malformed("Overlapping USDZ members", offset: secondLocal)) {
            try USDZArchive(bytes)
        }
    }
}
