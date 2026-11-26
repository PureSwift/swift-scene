import Testing
import SceneCore
@testable import SceneFormats

/// Writes small PNGs for the tests: rows filtered with filter 0, compressed with stored DEFLATE blocks.
private enum PNGWriter {

    static func file(width: Int, height: Int, bitDepth: UInt8, colorType: UInt8, rows: [[UInt8]],
                     palette: [UInt8]? = nil, transparency: [UInt8]? = nil) -> [UInt8] {
        var file: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        file += chunk("IHDR", uint32(UInt32(width)) + uint32(UInt32(height)) + [bitDepth, colorType, 0, 0, 0])
        if let palette { file += chunk("PLTE", palette) }
        if let transparency { file += chunk("tRNS", transparency) }
        file += chunk("IDAT", zlibStored(rows.flatMap { [0] + $0 }))
        file += chunk("IEND", [])
        return file
    }

    static func uint32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    }

    static func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
        let typed = Array(type.utf8) + data
        return uint32(UInt32(data.count)) + typed + uint32(crc32(typed))
    }

    static func zlibStored(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x78, 0x01]
        var offset = 0
        repeat {
            let count = min(65535, data.count - offset)
            let last: UInt8 = offset + count == data.count ? 1 : 0
            out += [last, UInt8(count & 0xFF), UInt8(count >> 8), UInt8(~count & 0xFF), UInt8((~count >> 8) & 0xFF)]
            out += data[offset ..< offset + count]
            offset += count
        } while offset < data.count
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return out + uint32(b << 16 | a)
    }

    static func crc32(_ data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 != 0 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
        }
        return ~crc
    }
}

@Suite struct PNGDecoderTests {

    private func pixel(_ image: ImageBuffer, _ x: Int, _ y: Int) -> [UInt8] {
        let p = y * image.bytesPerRow + x * 4
        return Array(image.pixels[p ..< p + 4])
    }

    @Test func rgba() throws {
        let png = PNGWriter.file(width: 2, height: 1, bitDepth: 8, colorType: 6, rows: [[255, 0, 0, 255, 0, 0, 255, 128]])
        let image = try PNGDecoder.decode(png)
        #expect(image.width == 2 && image.height == 1 && image.format == .rgba8)
        #expect(pixel(image, 0, 0) == [255, 0, 0, 255])
        #expect(pixel(image, 1, 0) == [0, 0, 255, 128])
    }

    @Test func rgbGainsOpaqueAlpha() throws {
        let png = PNGWriter.file(width: 1, height: 2, bitDepth: 8, colorType: 2, rows: [[10, 20, 30], [40, 50, 60]])
        let image = try PNGDecoder.decode(png)
        #expect(pixel(image, 0, 0) == [10, 20, 30, 255])
        // Rows from the top.
        #expect(pixel(image, 0, 1) == [40, 50, 60, 255])
    }

    @Test func greyAndGreyAlpha() throws {
        let grey = try PNGDecoder.decode(PNGWriter.file(width: 1, height: 1, bitDepth: 8, colorType: 0, rows: [[77]]))
        #expect(pixel(grey, 0, 0) == [77, 77, 77, 255])
        let greyAlpha = try PNGDecoder.decode(PNGWriter.file(width: 1, height: 1, bitDepth: 8, colorType: 4, rows: [[200, 50]]))
        #expect(pixel(greyAlpha, 0, 0) == [200, 200, 200, 50])
    }

    @Test func oneBitGrey() throws {
        // Eight pixels in one byte: 1010 1010.
        let image = try PNGDecoder.decode(PNGWriter.file(width: 8, height: 1, bitDepth: 1, colorType: 0, rows: [[0xAA]]))
        #expect(pixel(image, 0, 0) == [255, 255, 255, 255])
        #expect(pixel(image, 1, 0) == [0, 0, 0, 255])
    }

    @Test func paletteWithTransparency() throws {
        let png = PNGWriter.file(width: 2, height: 1, bitDepth: 8, colorType: 3, rows: [[0, 1]],
                                 palette: [255, 0, 0, 0, 255, 0], transparency: [64])
        let image = try PNGDecoder.decode(png)
        #expect(pixel(image, 0, 0) == [255, 0, 0, 64])
        #expect(pixel(image, 1, 0) == [0, 255, 0, 255])
    }

    @Test func sixteenBitsScaleToEight() throws {
        let png = PNGWriter.file(width: 1, height: 1, bitDepth: 16, colorType: 2, rows: [[0xFF, 0xFF, 0x80, 0x80, 0x00, 0x00]])
        let image = try PNGDecoder.decode(png)
        #expect(pixel(image, 0, 0) == [255, 128, 0, 255])
    }

    @Test func rejectsWhatIsntPNG() {
        #expect(throws: SceneFormatError.self) { try PNGDecoder.decode(Array("not a png".utf8)) }
        let png = PNGWriter.file(width: 4, height: 4, bitDepth: 8, colorType: 2, rows: Array(repeating: [UInt8](repeating: 9, count: 12), count: 4))
        #expect(throws: SceneFormatError.self) { try PNGDecoder.decode(Array(png.prefix(40))) }
        // A corrupted checksum.
        var corrupt = png
        corrupt[30] ^= 0xFF
        #expect(throws: SceneFormatError.self) { try PNGDecoder.decode(corrupt) }
    }

    @Test func textureLoaderDecodesBySignature() throws {
        let png = PNGWriter.file(width: 1, height: 1, bitDepth: 8, colorType: 2, rows: [[1, 2, 3]])
        #expect(TextureImageLoader.decode(png)?.width == 1)
        #expect(TextureImageLoader.decode([1, 2, 3]) == nil)
        #expect(TextureImageLoader.load(.path("/nonexistent/texture.png")) == nil)
    }
}
