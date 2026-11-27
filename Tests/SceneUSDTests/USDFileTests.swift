import Foundation
import Testing
import SceneCore
import SceneFormats
import SceneGraph
import SceneUSD

@Suite struct USDFileTests {
    private func fixture() throws -> [UInt8] {
        let url = try #require(Bundle.module.url(forResource: "triangle", withExtension: "usda", subdirectory: "Fixtures"))
        return Array(try Data(contentsOf: url))
    }

    @Test func fileRegistrationLoadsUSDAndPackagedUSDA() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = try fixture()
        for ext in ["usda", "USD", "usdz"] {
            let file = directory.appendingPathComponent("triangle." + ext)
            let data = ext == "usdz" ? try USDZArchive(entries: [.init(path: "root.usda", data: bytes)]).encoded() : bytes
            try Data(data).write(to: file)
            let strict = SceneAssetFile(url: file, decoders: USDSceneDecoder().fileDecoders)
            #expect(throws: SceneFormatError.self) { try strict.load() }
            let asset = SceneAssetFile(url: file, decoders: USDSceneDecoder(geometryOnly: true).fileDecoders)
            let scene = try asset.load()
            #expect(scene.rootNode.children.first?.name == "World")
            #expect(asset.dependencies == [file.standardizedFileURL])
            // Decoder selection belongs to this asset, not a process-global registry.
            #expect(throws: SceneFormatError.self) { try SceneAssetFile(url: file).load() }
        }
    }

    @Test func conversionPreservesExistingOutputOnFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("triangle.usda")
        let output = directory.appendingPathComponent("triangle.glb")
        try Data(fixture()).write(to: input)
        let decoders = USDSceneDecoder(geometryOnly: true).fileDecoders
        try SceneAssetConverter.convert(from: input, to: output, geometryOnly: true, decoders: decoders)
        let original = try Data(contentsOf: output)
        #expect(try GLTFDecoder().decodeScene(Array(original)).rootNode.hierarchyBoundingBox.isEmpty == false)
        #expect(throws: (any Error).self) {
            try SceneAssetConverter.convert(from: input, to: output, decoders: decoders)
        }
        #expect(throws: SceneFormatError.self) {
            try SceneAssetConverter.convert(from: input, to: output, overwrite: true, decoders: USDSceneDecoder().fileDecoders)
        }
        #expect(try Data(contentsOf: output) == original)
        try SceneAssetConverter.convert(from: input, to: output, overwrite: true, geometryOnly: true, decoders: decoders)
        #expect(try Data(contentsOf: output) == original)
        #expect(throws: SceneFormatError.self) {
            try SceneAssetConverter.convert(from: input, to: input, overwrite: true, decoders: decoders)
        }
    }

    @Test func crateAndMissingFilesHaveExplicitErrors() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".usdc")
        defer { try? FileManager.default.removeItem(at: file) }
        let asset = SceneAssetFile(url: file, decoders: USDSceneDecoder().fileDecoders)
        #expect(throws: SceneFormatError.self) { try asset.load() }
        #expect(asset.dependencies.contains(file.standardizedFileURL))
        try Data("PXR-USDC".utf8).write(to: file)
        #expect(throws: SceneFormatError.unsupported("USDC Crate layers")) { try asset.load() }
    }
}
