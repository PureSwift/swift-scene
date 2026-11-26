import PNG
import SceneCore

/// Reads PNG images, through PureSwift's swift-png, as RGBA with eight bits a channel: whatever the file's colour
/// type, depth, transparency or interlacing, the image comes out the one way textures want it.
public enum PNGDecoder {

    /// Whether the bytes start with PNG's signature.
    public static func isPNG(_ bytes: [UInt8]) -> Bool {
        bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    public static func decode(_ bytes: [UInt8]) throws(SceneFormatError) -> ImageBuffer {
        guard isPNG(bytes) else { throw .invalidHeader("Not a PNG image") }
        let source = Source(bytes)
        let host = Host(
            owner: Unmanaged.passUnretained(source).toOpaque(),
            allocate: { _, size in malloc(Int(size)) },
            deallocate: { _, memory in free(memory) },
            read: { owner, destination, count in
                guard let owner, let destination else { return }
                Unmanaged<Source>.fromOpaque(owner).takeUnretainedValue().read(into: destination, count: Int(count))
            },
            warn: { _, _, _ in },
            warnChunk: { _, _, _, _ in }
        )
        let context = PngContext(host: host, isReading: true)
        let info = InfoStore(host: host)
        defer {
            info.release()
            context.release()
        }
        do {
            return try withExtendedLifetime(source) { () throws(Diagnostic) -> ImageBuffer in
                try context.readInfo(into: info)
                guard let header = info.header else { throw Diagnostic("no header") }
                // Palettes and narrow greys to eight bits, transparency to alpha, sixteen bits to eight, grey to
                // colour, and an opaque alpha where there's none.
                context.transformFlags.insert([.expand, .expandTransparency, .scale16, .grayToRgb])
                if !header.colorType.hasAlpha {
                    context.fillerValue = 0xFF
                    context.fillerAfterColor = true
                    context.transformFlags.insert([.filler, .addAlpha])
                }
                if header.isInterlaced { _ = context.enableInterlaceHandling() }
                try context.updateInfoForClient(info)

                let width = header.width, height = header.height
                let rowBytes = info.rowBytes
                let channels = Int(info.channels), depth = Int(info.bitDepth)
                var pixels = [UInt8](repeating: 0, count: rowBytes * height)
                try pixels.withUnsafeMutableBufferPointer { (block) throws(Diagnostic) in
                    var rows: [UnsafeMutablePointer<UInt8>?] = (0..<height).map { block.baseAddress! + $0 * rowBytes }
                    try rows.withUnsafeMutableBufferPointer { (pointers) throws(Diagnostic) in
                        try context.readImage(rows: pointers.baseAddress!)
                    }
                }
                try context.readEnd(into: nil)
                guard channels == 4, depth == 8 else { throw Diagnostic("unexpected layout after transforms") }
                return ImageBuffer(width: width, height: height, format: .rgba8, bytesPerRow: rowBytes, pixels: pixels)
            }
        } catch {
            if source.isTruncated { throw .unexpectedEndOfData(offset: bytes.count) }
            let message = (error as? Diagnostic).map { "\($0.message)" } ?? "\(error)"
            throw .malformed("PNG: \(message)", offset: nil)
        }
    }

    /// The file's bytes, read in order; reading past the end gives zeros and marks the file truncated, since the
    /// read callback can't fail.
    private final class Source {
        let bytes: [UInt8]
        var offset = 0
        var isTruncated = false

        init(_ bytes: [UInt8]) {
            self.bytes = bytes
        }

        func read(into destination: UnsafeMutablePointer<UInt8>, count: Int) {
            let available = max(min(count, bytes.count - offset), 0)
            bytes.withUnsafeBufferPointer { source in
                if available > 0 { destination.update(from: source.baseAddress! + offset, count: available) }
            }
            if available < count {
                (destination + available).update(repeating: 0, count: count - available)
                isTruncated = true
            }
            offset += available
        }
    }
}

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
