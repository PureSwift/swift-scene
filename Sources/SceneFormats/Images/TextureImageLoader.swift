import SceneCore
import JPEG

/// Loads PNG and JPEG textures by their file signatures using pure Swift decoders.
public enum TextureImageLoader {

    public static func load(_ source: TextureSource) -> ImageBuffer? {
        switch source {
        case .image(let image):
            return image
        case .path(let path):
            guard let bytes = FileReader.read(path) else { return nil }
            return decode(bytes)
        case .named:
            return nil
        }
    }

    /// An image file's bytes, by their signature; nil for formats that aren't read.
    public static func decode(_ bytes: [UInt8]) -> ImageBuffer? {
        try? decodeImage(bytes)
    }

    public static func decodeImage(_ bytes: [UInt8]) throws(SceneFormatError) -> ImageBuffer {
        if PNGDecoder.isPNG(bytes) { return try PNGDecoder.decode(bytes) }
        guard bytes.starts(with: [0xff, 0xd8]) else { throw .unsupported("Unknown image format") }
        do {
            var stream = JPEGByteSource(bytes: bytes)
            let image: JPEG.Data.Rectangular<JPEG.Common> = try .decompress(stream: &stream)
            let rgb = image.unpack(as: JPEG.RGB.self)
            let pixels = rgb.flatMap { [$0.r, $0.g, $0.b, UInt8(255)] }
            return ImageBuffer(width: image.size.x, height: image.size.y, format: .rgba8, pixels: pixels)
        } catch {
            throw .malformed("JPEG: \(error)", offset: nil)
        }
    }
}

private struct JPEGByteSource: JPEG.Bytestream.Source {
    let bytes: [UInt8]
    var offset = 0

    mutating func read(count: Int) -> [UInt8]? {
        guard count >= 0, count <= bytes.count - offset else { return nil }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }
}

/// Reads whole files, for the loaders codecs take.
public enum FileReader {

    public static func read(_ path: String) -> [UInt8]? {
        guard let file = fopen(path, "rb") else { return nil }
        defer { fclose(file) }
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let count = fread(&buffer, 1, buffer.count, file)
            guard count > 0 else { break }
            bytes += buffer[0..<count]
        }
        return bytes
    }
}

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
