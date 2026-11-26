import SceneCore
import SceneGraph

/// Why an asset couldn't be read or written.
public enum SceneFormatError: Error, Hashable, Sendable {
    /// The data isn't in the format: a bad magic number, a header out of place.
    case invalidHeader(String)
    /// The data ends before it should.
    case unexpectedEndOfData(offset: Int)
    /// The data is in the format but says something wrong.
    case malformed(String, offset: Int?)
    /// The format allows it, but it isn't read or written yet.
    case unsupported(String)
}

/// Reads an asset format into a scene.
public protocol SceneAssetDecoder {

    /// The file name extensions the format uses, lower case, without the dot.
    static var fileExtensions: [String] { get }

    func decode(_ data: [UInt8]) async throws(SceneFormatError) -> Scene
}

/// Writes a scene in an asset format.
public protocol SceneAssetEncoder {

    static var fileExtensions: [String] { get }

    func encode(_ scene: Scene) async throws(SceneFormatError) -> [UInt8]
}

import BinaryParsing

extension SceneFormatError {

    /// A binary parser's error, as a format error: data ending early, or a value out of range.
    init(_ error: ParsingError) {
        if error.status == .insufficientData {
            self = .unexpectedEndOfData(offset: error.location ?? 0)
        } else if let format = error.userError as? SceneFormatError {
            self = format
        } else {
            self = .malformed("Invalid value", offset: error.location)
        }
    }
}
