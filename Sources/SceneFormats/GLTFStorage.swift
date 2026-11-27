import Foundation

public typealias SceneResourceLoader = (String) throws -> [UInt8]

struct GLTFStorage {
    let document: GLTFDocument
    let buffers: [[UInt8]]

    init(_ bytes: [UInt8], resourceLoader: SceneResourceLoader?) throws(SceneFormatError) {
        var json = bytes
        var binary: [UInt8]?
        if bytes.starts(with: [0x67, 0x6c, 0x54, 0x46]) {
            guard bytes.count >= 20, Self.word(bytes, 4) == 2, Int(Self.word(bytes, 8)) == bytes.count else {
                throw .invalidHeader("Invalid GLB 2.0 header")
            }
            var offset = 12
            var chunkIndex = 0
            var foundJSON = false
            while offset < bytes.count {
                guard bytes.count - offset >= 8 else { throw .unexpectedEndOfData(offset: offset) }
                let length = Int(Self.word(bytes, offset))
                let type = Self.word(bytes, offset + 4)
                offset += 8
                guard length % 4 == 0, length <= bytes.count - offset else {
                    throw .malformed("Invalid GLB chunk length", offset: offset)
                }
                if chunkIndex == 0 && type != 0x4e4f534a { throw .invalidHeader("GLB must begin with JSON") }
                if type == 0x4e4f534a {
                    guard !foundJSON else { throw .malformed("Duplicate GLB JSON chunk", offset: offset) }
                    json = Array(bytes[offset..<offset + length])
                    foundJSON = true
                } else if type == 0x004e4942 {
                    guard binary == nil, chunkIndex == 1 else { throw .malformed("Misplaced GLB binary chunk", offset: offset) }
                    binary = Array(bytes[offset..<offset + length])
                }
                offset += length
                chunkIndex += 1
            }
            guard foundJSON else { throw .invalidHeader("Missing GLB JSON") }
        }
        do { document = try JSONDecoder().decode(GLTFDocument.self, from: Data(json)) }
        catch { throw .malformed("Invalid glTF JSON: \(error)", offset: nil) }
        guard document.asset.version == "2.0", document.asset.minVersion == nil || document.asset.minVersion == "2.0" else {
            throw .unsupported("Only glTF 2.0 is supported")
        }
        guard (document.extensionsRequired ?? []).isEmpty else {
            throw .unsupported("Required glTF extensions: \((document.extensionsRequired ?? []).joined(separator: ", "))")
        }
        var loaded: [[UInt8]] = []
        for (index, buffer) in (document.buffers ?? []).enumerated() {
            guard buffer.byteLength >= 0 else { throw .malformed("Negative buffer length", offset: nil) }
            let data: [UInt8]
            if let uri = buffer.uri {
                data = try Self.resource(uri, loader: resourceLoader)
            } else if index == 0, let binary {
                guard binary.count - buffer.byteLength <= 3 else { throw .malformed("Excess GLB buffer padding", offset: nil) }
                data = binary
            } else { throw .malformed("Buffer has no URI or GLB data", offset: nil) }
            guard buffer.byteLength <= data.count else { throw .unexpectedEndOfData(offset: data.count) }
            loaded.append(Array(data.prefix(buffer.byteLength)))
        }
        buffers = loaded
    }

    static func resource(_ uri: String, loader: SceneResourceLoader?) throws(SceneFormatError) -> [UInt8] {
        if uri.hasPrefix("data:") {
            guard let comma = uri.firstIndex(of: ","), uri[..<comma].hasSuffix(";base64"),
                  let data = Data(base64Encoded: String(uri[uri.index(after: comma)...])) else {
                throw .malformed("Invalid base64 data URI", offset: nil)
            }
            return Array(data)
        }
        guard let loader else { throw .unsupported("An external resource loader is required for \(uri)") }
        do { return try loader(uri) }
        catch { throw .malformed("Cannot load resource \(uri): \(error)", offset: nil) }
    }

    static func word(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 |
        UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    func view(_ index: Int) throws(SceneFormatError) -> (bytes: [UInt8], view: GLTFDocument.BufferView) {
        let views = document.bufferViews ?? []
        guard views.indices.contains(index) else { throw .malformed("Invalid buffer view index", offset: nil) }
        let view = views[index]
        guard buffers.indices.contains(view.buffer) else { throw .malformed("Invalid buffer index", offset: nil) }
        let buffer = buffers[view.buffer]
        let offset = view.byteOffset ?? 0
        guard offset >= 0, offset <= buffer.count, view.byteLength >= 0, view.byteLength <= buffer.count - offset else {
            throw .malformed("Buffer view exceeds buffer", offset: offset)
        }
        return (Array(buffer[offset..<offset + view.byteLength]), view)
    }

    func accessor(_ index: Int) throws(SceneFormatError) -> (values: [Double], definition: GLTFDocument.Accessor) {
        let accessors = document.accessors ?? []
        guard accessors.indices.contains(index) else { throw .malformed("Invalid accessor index", offset: nil) }
        let accessor = accessors[index]
        let columns: Int
        let rows: Int
        switch accessor.type {
        case "SCALAR": columns = 1; rows = 1
        case "VEC2": columns = 1; rows = 2
        case "VEC3": columns = 1; rows = 3
        case "VEC4": columns = 1; rows = 4
        case "MAT2": columns = 2; rows = 2
        case "MAT3": columns = 3; rows = 3
        case "MAT4": columns = 4; rows = 4
        default: throw .malformed("Unknown accessor shape", offset: nil)
        }
        let width = try Self.width(accessor.componentType)
        let components = columns * rows
        let columnStride = columns > 1 ? (rows * width + 3) / 4 * 4 : rows * width
        let elementSize = columnStride * columns
        guard accessor.count > 0, accessor.count <= 16_777_216 / components else {
            throw .malformed("Accessor count exceeds supported size", offset: nil)
        }
        if accessor.normalized == true && ![5120, 5121, 5122, 5123].contains(accessor.componentType) {
            throw .malformed("Invalid normalized accessor type", offset: nil)
        }
        func read(_ bytes: [UInt8], offset: Int, stride: Int, count: Int) throws(SceneFormatError) -> [Double] {
            guard offset >= 0, offset % width == 0, stride >= elementSize, stride % width == 0,
                  offset <= bytes.count, elementSize <= bytes.count - offset,
                  count <= 1 + (bytes.count - offset - elementSize) / stride else {
                throw .malformed("Accessor exceeds buffer view", offset: offset)
            }
            var result: [Double] = []
            result.reserveCapacity(count * components)
            for index in 0..<count {
                for column in 0..<columns {
                    for row in 0..<rows {
                        result.append(try Self.number(bytes, at: offset + index * stride + column * columnStride + row * width,
                                                      type: accessor.componentType, normalized: accessor.normalized ?? false))
                    }
                }
            }
            return result
        }
        var values: [Double]
        if let index = accessor.bufferView {
            let (bytes, view) = try view(index)
            if let stride = view.byteStride, !(4...252).contains(stride) || stride % 4 != 0 {
                throw .malformed("Invalid buffer stride", offset: nil)
            }
            values = try read(bytes, offset: accessor.byteOffset ?? 0, stride: view.byteStride ?? elementSize, count: accessor.count)
        } else {
            guard accessor.byteOffset == nil || accessor.byteOffset == 0 else { throw .malformed("Offset without buffer view", offset: nil) }
            values = Array(repeating: 0, count: accessor.count * components)
        }
        if let sparse = accessor.sparse {
            guard sparse.count > 0, sparse.count <= accessor.count, [5121, 5123, 5125].contains(sparse.indices.componentType) else {
                throw .malformed("Invalid sparse accessor", offset: nil)
            }
            let indices = try view(sparse.indices.bufferView)
            let replacements = try view(sparse.values.bufferView)
            guard indices.view.byteStride == nil, replacements.view.byteStride == nil else {
                throw .malformed("Sparse views cannot be interleaved", offset: nil)
            }
            let indexWidth = try Self.width(sparse.indices.componentType)
            let offset = sparse.indices.byteOffset ?? 0
            guard offset >= 0, offset % indexWidth == 0, offset <= indices.bytes.count,
                  sparse.count <= (indices.bytes.count - offset) / indexWidth else {
                throw .malformed("Sparse indices exceed buffer view", offset: offset)
            }
            let replacementValues = try read(replacements.bytes, offset: sparse.values.byteOffset ?? 0,
                                             stride: elementSize, count: sparse.count)
            var previous = -1
            for index in 0..<sparse.count {
                let destination = Int(try Self.number(indices.bytes, at: offset + index * indexWidth,
                                                      type: sparse.indices.componentType, normalized: false))
                guard destination > previous, destination < accessor.count else {
                    throw .malformed("Sparse indices must be increasing and in range", offset: nil)
                }
                previous = destination
                values.replaceSubrange(destination * components..<(destination + 1) * components,
                                       with: replacementValues[index * components..<(index + 1) * components])
            }
        }
        return (values, accessor)
    }

    static func width(_ type: Int) throws(SceneFormatError) -> Int {
        switch type {
        case 5120, 5121: 1
        case 5122, 5123: 2
        case 5125, 5126: 4
        default: throw .malformed("Invalid component type", offset: nil)
        }
    }

    private static func number(_ bytes: [UInt8], at offset: Int, type: Int, normalized: Bool) throws(SceneFormatError) -> Double {
        let width = try width(type)
        var raw: UInt32 = 0
        for byte in 0..<width { raw |= UInt32(bytes[offset + byte]) << (byte * 8) }
        switch type {
        case 5120:
            let value = Double(Int8(bitPattern: UInt8(raw)))
            return normalized ? max(value / 127, -1) : value
        case 5121: return normalized ? Double(raw) / 255 : Double(raw)
        case 5122:
            let value = Double(Int16(bitPattern: UInt16(raw)))
            return normalized ? max(value / 32767, -1) : value
        case 5123: return normalized ? Double(raw) / 65535 : Double(raw)
        case 5125: return Double(raw)
        default:
            let value = Float(bitPattern: raw)
            guard value.isFinite else { throw .malformed("Non-finite accessor value", offset: offset) }
            return Double(value)
        }
    }
}
