import Foundation
import SceneGraph

/// File-to-file conversion of the current scene pose. Writes only after encoding succeeds.
public enum SceneAssetConverter {
    /// Additional output codecs keyed by lowercase extension, without the dot.
    public typealias Encoder = (Scene) throws(SceneFormatError) -> [UInt8]
    public static func convert(from input: URL, to output: URL, overwrite: Bool = false,
                               geometryOnly: Bool = false, cameraAspectRatio: Float? = nil,
                               decoders: [String: SceneAssetFile.Decoder] = [:],
                               encoders: [String: Encoder] = [:]) throws {
        let input = input.standardizedFileURL.resolvingSymlinksInPath()
        let output = output.standardizedFileURL.resolvingSymlinksInPath()
        guard input != output else { throw SceneFormatError.unsupported("Input and output must be different files") }
        let format = output.pathExtension.lowercased()
        guard encoders[format] != nil || ["glb", "3dmf", "3dm"].contains(format) else {
            throw SceneFormatError.unsupported("No encoder registered for .\(format)")
        }
        if !overwrite && FileManager.default.fileExists(atPath: output.path) {
            throw SceneFormatError.unsupported("Output already exists; use --force to replace it")
        }
        let scene = try SceneAssetFile(url: input, decoders: decoders).load()
        if geometryOnly {
            scene.rootNode.enumerateHierarchy { node, _ in node.camera = nil; node.light = nil }
        }
        let bytes: [UInt8]
        if let encoder = encoders[format] { bytes = try encoder(scene) }
        else if format == "glb" { bytes = try GLBEncoder(cameraAspectRatio: cameraAspectRatio).encodeScene(scene) }
        else { bytes = try ThreeDMFEncoder(encoding: .binary(.bigEndian)).encodeScene(scene) }
        if overwrite {
            try Data(bytes).write(to: output, options: .atomic)
        } else {
            // Publish a complete sibling file with a hard link: link creation is atomic and
            // fails if another writer creates the destination during encoding.
            let temporary = output.deletingLastPathComponent().appendingPathComponent(".scene-convert-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try Data(bytes).write(to: temporary, options: .withoutOverwriting)
            try FileManager.default.linkItem(at: temporary, to: output)
        }
    }
}
