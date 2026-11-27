import PNG
import SceneCore

/// Lossless PNG serialization for the integer pixel formats used by scene textures.
public enum PNGEncoder {
    public static func encode(_ image: ImageBuffer) throws(SceneFormatError) -> [UInt8] {
        let stride = image.format.bytesPerPixel
        guard image.width > 0, image.height > 0, image.width <= 16384, image.height <= 16384,
              image.bytesPerRow >= image.width * stride,
              image.bytesPerRow <= image.pixels.count / image.height else {
            throw .malformed("Invalid image dimensions or row storage", offset: nil)
        }
        guard image.format != .rgba32Float else { throw .unsupported("Floating-point PNG export") }
        let output = Output()
        let host = Host(
            owner: Unmanaged.passUnretained(output).toOpaque(),
            allocate: { _, size in UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8) },
            deallocate: { _, pointer in pointer?.deallocate() },
            read: { _, _, _ in }, warn: { _, _, _ in }, warnChunk: { _, _, _, _ in },
            writeBytes: { owner, bytes, count in
                guard let owner, let bytes else { return }
                Unmanaged<Output>.fromOpaque(owner).takeUnretainedValue().bytes.append(
                    contentsOf: UnsafeBufferPointer(start: bytes, count: Int(count)))
            }, flushBytes: { _ in })
        let writer = PngContext(host: host, isReading: false)
        let info = InfoStore(host: host)
        defer { info.release(); writer.release() }
        do {
            try writer.writeHeader(Header.Fields(width: UInt32(image.width), height: UInt32(image.height),
                bitDepth: 8, colorType: 6, compressionMethod: 0, filterMethod: 0, interlaceMethod: 0))
            try writer.writePalette(info)
            for y in 0..<image.height {
                var row: [UInt8] = []
                row.reserveCapacity(image.width * 4)
                for x in 0..<image.width {
                    let i = y * image.bytesPerRow + x * stride
                    let p = image.pixels
                    switch image.format {
                    case .rgba8: row += p[i..<i + 4]
                    case .bgra8: row += [p[i + 2], p[i + 1], p[i], p[i + 3]]
                    case .argb8: row += [p[i + 1], p[i + 2], p[i + 3], p[i]]
                    case .rgb8: row += [p[i], p[i + 1], p[i + 2], 255]
                    case .r8: row += [p[i], p[i], p[i], 255]
                    case .rgb555:
                        let value = UInt16(p[i]) << 8 | UInt16(p[i + 1])
                        func expand(_ channel: UInt16) -> UInt8 {
                            UInt8((channel & 31) << 3 | (channel & 31) >> 2)
                        }
                        row += [expand(value >> 10), expand(value >> 5), expand(value), 255]
                    case .rgba32Float: break
                    }
                }
                try row.withUnsafeMutableBufferPointer { try writer.writeRow($0.baseAddress) }
            }
            try writer.writeEnd(info)
        } catch { throw .malformed("PNG encoding failed: \(error)", offset: nil) }
        return output.bytes
    }

    private final class Output { var bytes: [UInt8] = [] }
}
