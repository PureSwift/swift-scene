import Foundation
import SceneFormats
import SceneGraph
import SceneUSD

/// Keeps the viewer camera and lights outside USD's unit/up-axis conversion transform.
/// The same decoder closures are reused on every hot reload, retaining the selected import options.
func makeViewerAsset(url: URL, geometryOnly: Bool = false) -> SceneAssetFile {
    let usd = ViewerUSDDecoder(decoder: USDSceneDecoder(geometryOnly: geometryOnly))
    var decoders: [String: SceneAssetFile.ResourceDecoder] = [:]
    for extensionName in usd.decoder.fileDecoders.keys {
        decoders[extensionName] = usd.decode
    }
    return SceneAssetFile(url: url, resourceDecoders: decoders)
}

private struct ViewerUSDDecoder {
    let decoder: USDSceneDecoder

    func decode(_ bytes: [UInt8], loader: @escaping SceneResourceLoader) throws(SceneFormatError) -> Scene {
        var resolved = decoder
        resolved.resourceLoader = loader
        let imported = try resolved.decodeScene(bytes)
        let scene = Scene()
        scene.background = imported.background
        scene.rootNode.addChild(imported.rootNode)
        return scene
    }
}
