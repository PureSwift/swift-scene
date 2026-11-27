import Foundation
import Testing
import SceneCore
import SceneFormats
import SceneGraph
import SceneUSD

@Suite struct USDExternalTextureTests {
    private let image = ImageBuffer(width: 1, height: 1, format: .rgba8, pixels: [255,64,32,128])

    private func archive() throws -> USDZArchive {
        var material = MaterialDescriptor.physicallyBased()
        material.diffuse = .texture(.image(image))
        material.alphaMode = .blend
        let geometry = Geometry(mesh: MeshBuffer(vertexCount: 3, streams: [
            VertexStream(semantic: .position, vectors: [SIMD3<Float>(0,0,0), SIMD3(1,0,0), SIMD3(0,1,0)]),
            VertexStream(semantic: .textureCoordinate(0), vectors: [SIMD2<Float>(0,0), SIMD2(1,0), SIMD2(0,1)])
        ], submeshes: [Submesh(range: 0..<3, materialIndex: 0)]), materials: [Material(material)])
        return try USDZArchive(USDSceneEncoder(encoding: .usdz).encodeScene(Scene { Node(geometry: geometry) }))
    }

    private func pixels(_ scene: Scene) throws -> ImageBuffer {
        var image: ImageBuffer?
        scene.rootNode.enumerateHierarchy { node, _ in
            if case .texture(.image(let value)) = node.geometry?.materials.first?.diffuse.contents { image = value }
        }
        return try #require(image)
    }

    @Test func fileResolutionTracksReloadsAndConverts() throws {
        let archive = try archive()
        let layer = try #require(archive.defaultLayer)
        let texture = try #require(archive.entries.first { $0.path.hasSuffix(".png") })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let textureURL = directory.appendingPathComponent("red #50%.png")
        let source = directory.appendingPathComponent("scene.usda")
        let text = String(decoding: layer.data, as: UTF8.self).replacingOccurrences(of: texture.path, with: textureURL.lastPathComponent)
        try Data(text.utf8).write(to: source)
        try Data(texture.data).write(to: textureURL)
        let decoder = USDSceneDecoder()
        let file = SceneAssetFile(url: source, resourceDecoders: decoder.resourceFileDecoders)
        #expect(try pixels(file.load()) == image)
        #expect(file.dependencies == [source.standardizedFileURL, textureURL.standardizedFileURL])
        let changed = ImageBuffer(width: 1, height: 1, format: .rgba8, pixels: [0,255,0,255])
        try Data(PNGEncoder.encode(changed)).write(to: textureURL)
        #expect(try pixels(file.load()) == changed)
        let output = directory.appendingPathComponent("scene.usdz")
        try SceneAssetConverter.convert(from: source, to: output,
            encoders: USDSceneEncoder().fileEncoders, resourceDecoders: decoder.resourceFileDecoders)
        #expect(try pixels(decoder.decodeScene(Array(Data(contentsOf: output)))) == changed)
        try FileManager.default.removeItem(at: textureURL)
        #expect(throws: SceneFormatError.self) { try file.load() }
        #expect(file.dependencies.contains(textureURL.standardizedFileURL))
    }

    @Test func standaloneRequiresResolverAndPackageNeverFallsBack() throws {
        let archive = try archive()
        let layer = try #require(archive.defaultLayer)
        #expect(throws: SceneFormatError.self) { try USDSceneDecoder().decodeScene(Array(layer.data)) }
        var requested: [String] = []
        let decoder = USDSceneDecoder(resourceLoader: { path in
            requested.append(path)
            return try PNGEncoder.encode(self.image)
        })
        #expect(try pixels(decoder.decodeScene(Array(layer.data))) == image)
        #expect(requested == ["textures/diffuse_0.png"])
        requested = []
        #expect(try pixels(decoder.decodeScene(archive.encoded())) == image)
        #expect(requested.isEmpty)
        let missing = try USDZArchive(entries: [layer]).encoded()
        #expect(throws: SceneFormatError.self) { try decoder.decodeScene(missing) }
        #expect(requested.isEmpty)
        _ = try USDSceneDecoder(geometryOnly: true).decodeScene(Array(layer.data))
    }

    @Test func rejectsExternalSchemesAndCorruptImages() throws {
        let archive = try archive()
        let layer = try #require(archive.defaultLayer)
        let decoder = USDSceneDecoder(resourceLoader: { _ in
            Issue.record("Unsupported path reached resource loader")
            return []
        })
        for path in ["https://example.com/image.png", "/tmp/image.png", "other.usdz[image.png]"] {
            let text = String(decoding: layer.data, as: UTF8.self).replacingOccurrences(of: "textures/diffuse_0.png", with: path)
            #expect(throws: SceneFormatError.self) { try decoder.decodeScene(Array(text.utf8)) }
        }
        let corrupt = USDSceneDecoder(resourceLoader: { _ in [0,1,2] })
        #expect(throws: SceneFormatError.self) { try corrupt.decodeScene(Array(layer.data)) }
    }
}
