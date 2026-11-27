import Foundation

indirect enum AssetPlistValue {
    case null, boolean(Bool), integer(Int64), real(Double), string(String), data([UInt8]), uid(Int)
    case array([AssetPlistValue]), dictionary([String: AssetPlistValue])

    var dictionary: [String: AssetPlistValue]? { if case .dictionary(let value) = self { value } else { nil } }
    var array: [AssetPlistValue]? { if case .array(let value) = self { value } else { nil } }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var data: [UInt8]? { if case .data(let value) = self { value } else { nil } }
    var number: Double? {
        switch self {
        case .integer(let value): Double(value)
        case .real(let value): value
        case .boolean(let value): value ? 1 : 0
        default: nil
        }
    }
}

/// Binary property-list reader that preserves keyed-archive UIDs without instantiating archived classes.
struct BinaryPropertyList {
    let bytes: [UInt8]
    private var offsets: [Int] = []
    private var referenceSize = 0
    private var objectEnd = 0
    private var cache: [Int: AssetPlistValue] = [:]
    private var resolving: Set<Int> = []
    private var decodedCount = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func parse() throws(SceneFormatError) -> AssetPlistValue {
        guard bytes.count >= 40, bytes.starts(with: Array("bplist00".utf8)) else {
            throw .invalidHeader("Expected a binary property list")
        }
        let trailer = bytes.count - 32
        let offsetSize = Int(bytes[trailer + 6])
        referenceSize = Int(bytes[trailer + 7])
        let count = try size(trailer + 8, width: 8)
        let root = try size(trailer + 16, width: 8)
        objectEnd = try size(trailer + 24, width: 8)
        guard (1...8).contains(offsetSize), (1...8).contains(referenceSize),
              count > 0, count <= 1_000_000, root < count, objectEnd >= 8, objectEnd <= trailer,
              count <= (trailer - objectEnd) / offsetSize else { throw .invalidHeader("Invalid property-list trailer") }
        for index in 0..<count {
            let offset = try size(objectEnd + index * offsetSize, width: offsetSize)
            guard offset >= 8, offset < objectEnd else { throw .malformed("Invalid object offset", offset: offset) }
            offsets.append(offset)
        }
        return try object(root, depth: 0)
    }

    private func unsigned(_ offset: Int, width: Int) throws(SceneFormatError) -> UInt64 {
        guard (1...8).contains(width), offset >= 0, offset <= bytes.count, width <= bytes.count - offset else {
            throw .unexpectedEndOfData(offset: offset)
        }
        var value: UInt64 = 0
        for byte in bytes[offset..<offset + width] { value = value << 8 | UInt64(byte) }
        return value
    }

    private func size(_ offset: Int, width: Int) throws(SceneFormatError) -> Int {
        guard let value = Int(exactly: try unsigned(offset, width: width)) else {
            throw .malformed("Property-list size exceeds host integer", offset: offset)
        }
        return value
    }

    private mutating func object(_ index: Int, depth: Int) throws(SceneFormatError) -> AssetPlistValue {
        guard offsets.indices.contains(index), depth < 256 else { throw .malformed("Invalid property-list reference", offset: nil) }
        if let value = cache[index] { return value }
        guard resolving.insert(index).inserted else { throw .malformed("Cyclic property-list object", offset: nil) }
        defer { resolving.remove(index) }
        decodedCount += 1
        guard decodedCount <= 1_000_000 else { throw .unsupported("Property list exceeds object limit") }
        var offset = offsets[index]
        let marker = bytes[offset]
        offset += 1
        let type = marker >> 4
        var count = Int(marker & 15)
        if [4, 5, 6, 7, 10, 12, 13].contains(type), count == 15 {
            guard offset < objectEnd, bytes[offset] >> 4 == 1, bytes[offset] & 15 <= 3 else {
                throw .malformed("Invalid extended object length", offset: offset)
            }
            let width = 1 << Int(bytes[offset] & 15)
            offset += 1
            guard width <= objectEnd - offset else { throw .unexpectedEndOfData(offset: offset) }
            count = try size(offset, width: width)
            offset += width
        }
        func require(_ count: Int) throws(SceneFormatError) {
            guard offset <= objectEnd, count >= 0, count <= objectEnd - offset else {
                throw .unexpectedEndOfData(offset: offset)
            }
        }
        try require(0)
        let value: AssetPlistValue
        switch type {
        case 0:
            switch marker {
            case 0: value = .null
            case 8: value = .boolean(false)
            case 9: value = .boolean(true)
            default: throw .unsupported("Property-list singleton")
            }
        case 1:
            guard count <= 3 else { throw .unsupported("Property-list integer wider than 64 bits") }
            let width = 1 << count
            try require(width)
            let raw = try unsigned(offset, width: width)
            value = .integer(Int64(bitPattern: raw))
        case 2, 3:
            let width = type == 3 ? 8 : 1 << count
            guard width == 4 || width == 8 else { throw .malformed("Invalid real width", offset: offset) }
            try require(width)
            let raw = try unsigned(offset, width: width)
            let number = width == 4 ? Double(Float(bitPattern: UInt32(raw))) : Double(bitPattern: raw)
            guard number.isFinite else { throw .malformed("Non-finite property-list number", offset: offset) }
            value = .real(number)
        case 4:
            try require(count)
            value = .data(Array(bytes[offset..<offset + count]))
        case 5, 7:
            try require(count)
            guard let string = String(bytes: bytes[offset..<offset + count], encoding: type == 5 ? .ascii : .utf8) else {
                throw .malformed("Invalid property-list string", offset: offset)
            }
            value = .string(string)
        case 6:
            guard count <= (objectEnd - offset) / 2 else { throw .unexpectedEndOfData(offset: offset) }
            var units: [UInt16] = []
            for index in 0..<count { units.append(UInt16(try unsigned(offset + index * 2, width: 2))) }
            value = .string(String(decoding: units, as: UTF16.self))
        case 8:
            let width = count + 1
            try require(width)
            value = .uid(try size(offset, width: width))
        case 10, 12:
            guard count <= (objectEnd - offset) / referenceSize else { throw .unexpectedEndOfData(offset: offset) }
            var array: [AssetPlistValue] = []
            for index in 0..<count { array.append(try object(size(offset + index * referenceSize, width: referenceSize), depth: depth + 1)) }
            value = .array(array)
        case 13:
            guard count <= (objectEnd - offset) / referenceSize / 2 else { throw .unexpectedEndOfData(offset: offset) }
            var dictionary: [String: AssetPlistValue] = [:]
            for index in 0..<count {
                guard let key = try object(size(offset + index * referenceSize, width: referenceSize), depth: depth + 1).string,
                      dictionary[key] == nil else { throw .malformed("Invalid property-list dictionary key", offset: offset) }
                dictionary[key] = try object(size(offset + (count + index) * referenceSize, width: referenceSize), depth: depth + 1)
            }
            value = .dictionary(dictionary)
        default: throw .unsupported("Property-list marker \(marker)")
        }
        cache[index] = value
        return value
    }
}
