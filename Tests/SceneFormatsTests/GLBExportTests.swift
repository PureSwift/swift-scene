import Foundation
import Testing
import SceneCore
import SceneGraph
@testable import SceneFormats

@Suite struct GLBExportTests {
    private func scene() -> Scene {
        let scene = Scene()
        let parent = Node(name: "parent")
        parent.position = [2, 3, 4]
        let child = Node(name: "box", geometry: .box())
        child.scale = [2, 1, 3]
        parent.addChild(child)
        scene.rootNode.addChild(parent)
        return scene
    }

    @Test func hierarchyGeometryAndContainer() throws {
        let original = scene()
        let data = try GLBEncoder().encodeScene(original)
        #expect(data.count % 4 == 0)
        func word(_ offset: Int) -> UInt32 {
            (0..<4).reduce(0) { $0 | UInt32(data[offset + $1]) << ($1 * 8) }
        }
        #expect(word(0) == 0x46546c67)
        #expect(word(4) == 2)
        #expect(Int(word(8)) == data.count)
        #expect(word(16) == 0x4e4f534a)
        let jsonLength = Int(word(12))
        #expect(word(24 + jsonLength) == 0x004e4942)
        let json = try #require(JSONSerialization.jsonObject(with: Data(data[20..<20 + jsonLength])) as? [String: Any])
        let accessors = try #require(json["accessors"] as? [[String: Any]])
        #expect(accessors[0]["min"] != nil)
        #expect(accessors[0]["max"] != nil)
        let decoded = try GLTFDecoder().decodeScene(data)
        let box = try #require(decoded.rootNode.childNode(named: "box"))
        #expect(box.worldPosition == SIMD3(2, 3, 4))
        #expect(box.scale == SIMD3(2, 1, 3))
        let geometry = try #require(box.children.first?.geometry)
        let originalMesh = try #require(original.rootNode.childNode(named: "box")?.geometry?.mesh)
        #expect(geometry.mesh.positions == originalMesh.positions)
        #expect(box.children.reduce(0) { $0 + ($1.geometry?.mesh.indices?.count ?? 0) } == originalMesh.vertexCount)
        #expect(try GLBEncoder().encodeScene(original) == data)
    }

    @Test func embeddedTextureUnlitAndOpacity() throws {
        let original = scene()
        let box = try #require(original.rootNode.childNode(named: "box"))
        let image = ImageBuffer(width: 2, height: 1, format: .rgba8, pixels: [255, 0, 0, 255, 0, 255, 0, 128])
        var descriptor = MaterialDescriptor.unlit(color: [1, 1, 1, 1])
        descriptor.diffuse = .texture(.image(image))
        descriptor.diffuse.sampler = TextureSampler(wrapS: .repeat, wrapT: .mirror, mipFilter: .linear)
        box.geometry?.materials = [Material(descriptor)]
        box.opacity = 0.5
        box.parent?.opacity = 0.5
        let decoded = try GLTFDecoder().decodeScene(GLBEncoder().encodeScene(original))
        let material = try #require(decoded.rootNode.childNode(named: "box")?.children.first?.geometry?.firstMaterial)
        #expect(material.lightingModel == .unlit)
        #expect(material.descriptor.diffuseFactor.w == 0.25)
        #expect(material.descriptor.alphaMode == .blend)
        #expect(material.diffuse.sampler.wrapS == .repeat)
        #expect(material.diffuse.sampler.wrapT == .mirror)
        guard case .texture(.image(let result)) = material.diffuse.contents else {
            Issue.record("Embedded texture was not decoded"); return
        }
        #expect(result.pixels == image.pixels)
    }

    @Test func multipleSubmeshesAndNonindexedGeometry() throws {
        let mesh = MeshBuffer(vertexCount: 6, streams: [
            VertexStream(semantic: .position, vectors: [SIMD3<Float>(0, 0, 0), [1, 0, 0], [0, 1, 0],
                                                       [0, 0, 1], [1, 0, 1], [0, 1, 1]])],
            submeshes: [Submesh(range: 0..<3, materialIndex: 1), Submesh(range: 3..<6, materialIndex: 0)])
        let original = Scene()
        original.rootNode.addChild(Node(geometry: Geometry(mesh: mesh, materials: [
            Material(.physicallyBased(baseColor: [1, 0, 0, 1], metalness: 0.3, roughness: 0.7)),
            Material(.unlit(color: [0, 1, 0, 1]))])))
        let decoded = try GLTFDecoder().decodeScene(GLBEncoder().encodeScene(original))
        let geometries = decoded.rootNode.childNodes { $0.geometry != nil }.compactMap(\.geometry)
        #expect(geometries.count == 2)
        #expect(geometries[0].firstMaterial?.lightingModel == .unlit)
        #expect(geometries[0].firstMaterial?.diffuse.color == SIMD4(0, 1, 0, 1))
        #expect(geometries[1].firstMaterial?.descriptor.metalness.color?.x == 0.3)
        #expect(geometries[1].mesh.indices?[0] == 3)
    }

    @Test func visibilityAndEmptyScenes() throws {
        let original = scene()
        original.rootNode.children[0].isHidden = true
        let decoded = try GLTFDecoder().decodeScene(GLBEncoder().encodeScene(original))
        #expect(decoded.rootNode.childNodes { $0.geometry != nil }.isEmpty)
        original.rootNode.isHidden = true
        let emptyBytes = try GLBEncoder().encodeScene(original)
        let empty = try GLTFDecoder().decodeScene(emptyBytes)
        #expect(empty.rootNode.children.isEmpty)
        let jsonLength = (0..<4).reduce(0) { $0 | Int(emptyBytes[12 + $1]) << ($1 * 8) }
        let document = try #require(JSONSerialization.jsonObject(with: Data(emptyBytes[20..<20 + jsonLength])) as? [String: Any])
        let scenes = try #require(document["scenes"] as? [[String: Any]])
        #expect(scenes[0]["nodes"] == nil) // glTF forbids an empty nodes array.
    }

    @Test func rejectsInvalidMeshesAndUnsupportedFeatures() throws {
        let original = scene()
        let box = try #require(original.rootNode.childNode(named: "box"))
        box.camera = Camera()
        #expect(throws: SceneFormatError.self) { try GLBEncoder().encodeScene(original) }
        #expect(throws: Never.self) { try GLBEncoder(omitCamerasAndLights: true).encodeScene(original) }
        box.camera = nil
        var mesh = try #require(box.geometry?.mesh)
        mesh.indices = .uint32([0, 1, UInt32.max])
        mesh.submeshes = [Submesh(range: 0..<3, materialIndex: 0)]
        box.geometry = Geometry(mesh: mesh)
        #expect(throws: SceneFormatError.self) { try GLBEncoder().encodeScene(original) }
        mesh.indices = nil
        mesh.streams[0].data[0] = .nan
        box.geometry = Geometry(mesh: mesh)
        #expect(throws: SceneFormatError.self) { try GLBEncoder().encodeScene(original) }
        box.geometry = .box()
        box.geometry?.firstMaterial?.diffuse = .texture(.named("missing"))
        #expect(throws: SceneFormatError.self) { try GLBEncoder().encodeScene(original) }
    }

    @Test func pngPixelFormatsAndRowPadding() throws {
        let cases: [(ImageBuffer.PixelFormat, [UInt8], [UInt8])] = [
            (.rgba8, [1, 2, 3, 4], [1, 2, 3, 4]),
            (.bgra8, [3, 2, 1, 4], [1, 2, 3, 4]),
            (.argb8, [4, 1, 2, 3], [1, 2, 3, 4]),
            (.rgb8, [1, 2, 3], [1, 2, 3, 255]),
            (.r8, [9], [9, 9, 9, 255]),
            (.rgb555, [0x7c, 0], [255, 0, 0, 255])
        ]
        for (format, pixels, expected) in cases {
            let image = ImageBuffer(width: 1, height: 2, format: format,
                bytesPerRow: pixels.count + 1, pixels: pixels + [99] + pixels + [99])
            let decoded = try PNGDecoder.decode(PNGEncoder.encode(image))
            #expect(decoded.pixels == expected + expected)
        }
        var invalid = ImageBuffer(width: 1, height: 1, format: .r8, pixels: [0])
        invalid.bytesPerRow = Int.max
        #expect(throws: SceneFormatError.self) { try PNGEncoder.encode(invalid) }
    }

    @Test func fileConversionProtectsExistingOutput() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("triangle.obj")
        try Data("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n".utf8).write(to: input)
        let output = directory.appendingPathComponent("triangle.glb")
        try SceneAssetConverter.convert(from: input, to: output)
        let bytes = try Data(contentsOf: output)
        #expect(!bytes.isEmpty)
        #expect(throws: (any Error).self) { try SceneAssetConverter.convert(from: input, to: output) }
        #expect(try Data(contentsOf: output) == bytes)
        try SceneAssetConverter.convert(from: input, to: output, overwrite: true)
        let threeDMF = directory.appendingPathComponent("triangle.3dmf")
        try SceneAssetConverter.convert(from: input, to: threeDMF)
        #expect(try SceneAssetFile(url: threeDMF).load().rootNode.childNodes { $0.geometry != nil }.count == 1)
        #expect(throws: (any Error).self) { try SceneAssetConverter.convert(from: input, to: input, overwrite: true) }
        let unsupported = directory.appendingPathComponent("triangle.usdz")
        #expect(throws: (any Error).self) { try SceneAssetConverter.convert(from: input, to: unsupported) }
        #expect(!FileManager.default.fileExists(atPath: unsupported.path))
        let broken = directory.appendingPathComponent("broken.glb")
        try Data([0, 1, 2]).write(to: broken)
        #expect(throws: (any Error).self) { try SceneAssetConverter.convert(from: broken, to: output, overwrite: true) }
        #expect(try Data(contentsOf: output) == bytes)
    }

    @Test func scnFixtureConvertsWithExplicitGeometryOnly() throws {
        let fixture = try #require(Bundle.module.url(forResource: "reference", withExtension: "scn", subdirectory: "Fixtures"))
        let scene = try SceneAssetFile(url: fixture).load()
        #expect(throws: SceneFormatError.self) { try GLBEncoder().encodeScene(scene) }
        let result = try GLTFDecoder().decodeScene(GLBEncoder(omitCamerasAndLights: true).encodeScene(scene))
        let primitiveCount = scene.rootNode.childNodes { $0.geometry != nil }.reduce(0) { $0 + ($1.geometry?.mesh.submeshes.count ?? 0) }
        #expect(result.rootNode.childNodes { $0.geometry != nil }.count == primitiveCount)
    }
}
