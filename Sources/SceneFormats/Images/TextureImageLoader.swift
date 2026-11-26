import SceneCore

/// Reads the images textures name, for a renderer's texture loader: a path's file decoded by its contents. PNG for
/// now; other formats, and names that aren't paths, give nil.
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
        if PNGDecoder.isPNG(bytes) { return try? PNGDecoder.decode(bytes) }
        return nil
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
