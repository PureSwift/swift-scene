import SceneFormats

public extension USDSceneDecoder {
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
