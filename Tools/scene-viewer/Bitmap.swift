#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import SceneCore

/// Writes an RGBA image as a 24-bit Windows bitmap, which every platform's image tools open.
func writeBitmap(_ image: ImageBuffer, to path: String) -> Bool {
    precondition(image.format == .rgba8, "Bitmaps are written from RGBA")
    let rowBytes = (image.width * 3 + 3) & ~3
    let pixelBytes = rowBytes * image.height
    var data = [UInt8]()
    data.reserveCapacity(54 + pixelBytes)
    func append32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { data.append(contentsOf: $0) } }
    func append16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { data.append(contentsOf: $0) } }
    data.append(contentsOf: Array("BM".utf8))
    append32(54 + pixelBytes)
    append32(0)
    append32(54)
    append32(40)
    append32(image.width)
    append32(image.height)
    append16(1)
    append16(24)
    append32(0)
    append32(pixelBytes)
    append32(2835)
    append32(2835)
    append32(0)
    append32(0)
    // Rows from the bottom, blue first.
    for row in (0..<image.height).reversed() {
        let start = row * image.bytesPerRow
        for x in 0..<image.width {
            let p = start + x * 4
            data.append(contentsOf: [image.pixels[p + 2], image.pixels[p + 1], image.pixels[p]])
        }
        data.append(contentsOf: repeatElement(0, count: rowBytes - image.width * 3))
    }
    guard let file = fopen(path, "wb") else { return false }
    defer { fclose(file) }
    return data.withUnsafeBytes { fwrite($0.baseAddress, 1, $0.count, file) } == data.count
}

/// A file's bytes.
func readFile(_ path: String) -> [UInt8]? {
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
