// Ported from Quesa's pixmap reading (E3FFR_3DMF_Geometry.cpp) and pixel types (Quesa.h).
// Copyright (c) 1999-2021, Quesa Developers. All rights reserved.
// Licensed under the BSD 3-Clause License; see LICENSE-Quesa.

import SceneCore

/// QuickDraw 3D's pixmaps: what `PixmapTexture` and `MipmapTexture` hold.
enum Pixmap {

    /// `TQ3PixelType`.
    enum PixelType: UInt32 {
        case rgb32 = 0
        case argb32 = 1
        case rgb16 = 2
        case argb16 = 3
        case rgb16_565 = 4
        case rgb24 = 5

        static let names: [String: UInt32] = [
            "rgb32": 0, "argb32": 1, "rgb16": 2, "argb16": 3, "rgb16_565": 4, "rgb24": 5,
        ]

        var bytesPerPixel: Int {
            switch self {
            case .rgb32, .argb32: 4
            case .rgb16, .argb16, .rgb16_565: 2
            case .rgb24: 3
            }
        }
    }

    /// `TQ3Endian` names.
    static let endianNames: [String: UInt32] = ["bigendian": 0, "littleendian": 1]

    /// Reads a pixmap's fields — width, height, row bytes, pixel size, pixel type, bit order, byte order — and its
    /// rows, as an RGBA image with rows from the top.
    static func read(_ reader: inout MetafileDataReader) throws(SceneFormatError) -> ImageBuffer {
        let width = Int(try reader.uint32())
        let height = Int(try reader.uint32())
        let rowBytes = Int(try reader.uint32())
        _ = try reader.uint32() // Pixel size, which the type implies.
        let typeValue = try reader.enumerated(PixelType.names)
        _ = try reader.enumerated(endianNames) // Bit order, which only matters below a byte.
        let littleEndian = try reader.enumerated(endianNames) == 1
        guard let type = PixelType(rawValue: typeValue) else {
            throw .unsupported("Pixel type \(typeValue)")
        }
        guard width > 0, height > 0, rowBytes >= width * type.bytesPerPixel, rowBytes * height < 1 << 28 else {
            throw .malformed("A \(width)×\(height) pixmap with \(rowBytes) bytes a row", offset: nil)
        }
        let raw = try reader.rawBytes(rowBytes * height)
        return convert(raw, width: width, height: height, rowBytes: rowBytes, type: type, littleEndian: littleEndian)
    }

    static func convert(_ raw: [UInt8], width: Int, height: Int, rowBytes: Int, type: PixelType, littleEndian: Bool) -> ImageBuffer {
        var rgba = [UInt8]()
        rgba.reserveCapacity(width * height * 4)
        let size = type.bytesPerPixel
        for row in 0..<height {
            for column in 0..<width {
                let p = row * rowBytes + column * size
                // The pixel as a number, in its byte order.
                var value: UInt32 = 0
                for i in 0..<size {
                    value = value << 8 | UInt32(raw[p + (littleEndian ? size - 1 - i : i)])
                }
                rgba.append(contentsOf: decode(value, type))
            }
        }
        return ImageBuffer(width: width, height: height, format: .rgba8, pixels: rgba)
    }

    private static func decode(_ v: UInt32, _ type: PixelType) -> [UInt8] {
        func five(_ c: UInt32) -> UInt8 { let c = c & 0x1F; return UInt8(c << 3 | c >> 2) }
        func six(_ c: UInt32) -> UInt8 { let c = c & 0x3F; return UInt8(c << 2 | c >> 4) }
        switch type {
        case .rgb32, .rgb24:
            return [UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF), 255]
        case .argb32:
            return [UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF), UInt8(v >> 24 & 0xFF)]
        case .rgb16:
            return [five(v >> 10), five(v >> 5), five(v), 255]
        case .argb16:
            return [five(v >> 10), five(v >> 5), five(v), v & 0x8000 != 0 ? 255 : 0]
        case .rgb16_565:
            return [five(v >> 11), six(v >> 5), five(v), 255]
        }
    }
}
