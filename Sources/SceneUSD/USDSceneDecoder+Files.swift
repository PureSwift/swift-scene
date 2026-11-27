import SceneFormats
import SceneGraph

public extension USDSceneDecoder {
    /// Local image resolution and dependency tracking for file-based loading.
    var resourceFileDecoders: [String: SceneAssetFile.ResourceDecoder] {
        var result: [String: SceneAssetFile.ResourceDecoder] = [:]
        for extensionName in Self.fileExtensions + ["usdc"] {
            result[extensionName] = decodeWithResources
        }
        return result
    }

    private func decodeWithResources(_ bytes: [UInt8], loader: @escaping SceneResourceLoader) throws(SceneFormatError) -> Scene {
        var decoder = self
        decoder.resourceLoader = loader
        return try decoder.decodeScene(bytes)
    }

    /// Registers this decoder's options with a SceneAssetFile or SceneAssetConverter.
    /// USDC is included to report an explicit unsupported-Crate error, not a missing-codec error.
    var fileDecoders: [String: SceneAssetFile.Decoder] {
        var result: [String: SceneAssetFile.Decoder] = [:]
        for extensionName in Self.fileExtensions + ["usdc"] {
            result[extensionName] = self.decodeScene
        }
        return result
    }
}
