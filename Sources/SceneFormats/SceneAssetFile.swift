import Foundation
import SceneGraph

/// Local asset loading with dependency tracking for editors and hot-reloading viewers.
public final class SceneAssetFile {
    public let url: URL
    public private(set) var dependencies: Set<URL> = []

    public init(url: URL) { self.url = url.standardizedFileURL }

    public func load() throws(SceneFormatError) -> Scene {
        dependencies = [url]
        let bytes = try read(url)
        let loader: SceneResourceLoader = { [self] uri in
            guard let reference = URL(string: uri, relativeTo: url), reference.isFileURL else {
                throw SceneFormatError.unsupported("Only local file resources are supported: \(uri)")
            }
            return try read(reference.standardizedFileURL)
        }
        switch url.pathExtension.lowercased() {
        case "3dmf", "3dm": return try ThreeDMFDecoder().decodeScene(bytes)
        case "gltf", "glb": return try GLTFDecoder(resourceLoader: loader).decodeScene(bytes)
        case "dae": return try ColladaDecoder(resourceLoader: loader).decodeScene(bytes)
        case "scn":
            var decoder = SCNArchiveDecoder(resourceLoader: loader)
            decoder.sourcePath = url.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.lastPathComponent
            return try decoder.decodeScene(bytes)
        case "obj":
            return try WavefrontOBJDecoder(baseDirectory: url.deletingLastPathComponent().path,
                materialLibraryLoader: { [self] path in try? read(URL(fileURLWithPath: path)) }).decodeScene(bytes)
        default: throw .unsupported("No decoder for .\(url.pathExtension)")
        }
    }

    /// Records texture dependencies resolved lazily by a renderer, including OBJ material maps.
    public func readTexture(_ path: String) -> [UInt8]? { try? read(URL(fileURLWithPath: path)) }

    private func read(_ url: URL) throws(SceneFormatError) -> [UInt8] {
        dependencies.insert(url.standardizedFileURL)
        do { return [UInt8](try Data(contentsOf: url)) }
        catch { throw .malformed("Cannot read \(url.path): \(error.localizedDescription)", offset: nil) }
    }
}
