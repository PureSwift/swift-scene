import Testing
import SceneCore
import SceneFormats
import SceneGraph
import SceneUSD

@Suite struct USDUnlitTextureTests {
    private let image = ImageBuffer(width: 1, height: 2, format: .rgba8, pixels: [255,0,0,0, 0,0,255,128])

    private func scene(mode: MaterialDescriptor.AlphaMode) -> Scene {
        var descriptor = MaterialDescriptor.unlit(color: SIMD4(repeating: 1))
        descriptor.diffuse = .texture(.image(image))
        descriptor.diffuseFactor = SIMD4(0.5,0.25,1,0.5)
        descriptor.diffuse.intensity = 0.5
        descriptor.alphaMode = mode
        let geometry = Geometry(mesh: MeshBuffer(vertexCount: 3, streams: [
            VertexStream(semantic: .position, vectors: [SIMD3<Float>(0,0,0), SIMD3(1,0,0), SIMD3(0,1,0)]),
            VertexStream(semantic: .textureCoordinate(0), vectors: [SIMD2<Float>(0,0), SIMD2(1,0), SIMD2(0,1)])
        ], submeshes: [Submesh(range: 0..<3, materialIndex: 0)]), materials: [Material(descriptor)])
        let scene = Scene { Node(geometry: geometry) }
        scene.rootNode.opacity = 0.5
        return scene
    }

    private func material(_ scene: Scene) throws -> Material {
        var result: Material?
        scene.rootNode.enumerateHierarchy { node, _ in if let material = node.geometry?.materials.first { result = material } }
        return try #require(result)
    }

    @Test(arguments: [MaterialDescriptor.AlphaMode.blend, .opaque, .mask(cutoff: 0.2)])
    func unlitTextureRoundTrip(mode: MaterialDescriptor.AlphaMode) throws {
        let source = scene(mode: mode)
        let encoder = USDSceneEncoder(encoding: .usdz)
        let bytes = try encoder.encodeScene(source)
        let archive = try USDZArchive(bytes)
        #expect(archive.entries.count == 2)
        let stage = try USDStage(archive: archive)
        let shader = try #require(stage.traverse().first { $0.name == "Shader" })
        #expect(shader[property: "inputs:ior"]?.value == .number("1"))
        #expect(shader[property: "inputs:diffuseColor.connect"] == nil)
        #expect(shader[property: "inputs:emissiveColor.connect"] != nil)
        #expect((shader[property: "inputs:opacity.connect"] == nil) == (mode == .opaque))
        let restoredScene = try USDSceneDecoder().decodeScene(bytes)
        let restored = try material(restoredScene).descriptor
        #expect(restored.lightingModel == .unlit)
        #expect(restored.alphaMode == mode)
        #expect(restored.diffuseFactor == SIMD4(0.25,0.125,0.5,mode == .opaque ? 1 : 0.25))
        var expected = image
        if mode == .opaque { expected.pixels[3] = 255; expected.pixels[7] = 255 }
        #expect(restored.diffuse.contents == .texture(.image(expected)))
        #expect(try material(USDSceneDecoder().decodeScene(encoder.encodeScene(restoredScene))).descriptor == restored)
        let gltf = try GLTFDecoder().decodeScene(GLBEncoder().encodeScene(restoredScene))
        #expect(try material(gltf).descriptor.lightingModel == .unlit)
        #expect(try material(gltf).descriptor.diffuseFactor == restored.diffuseFactor)
    }

    @Test func rejectsAdditionalEmissionAndUnlitDataMaps() throws {
        let source = scene(mode: .blend)
        let surface = try material(source)
        let original = surface.descriptor
        for slot in 0..<3 {
            var descriptor = original
            if slot == 0 { descriptor.emission = .color(SIMD4(1,0,0,1)) }
            if slot == 1 { descriptor.normal = .texture(.image(image)) }
            if slot == 2 { descriptor.emission = .texture(.image(image)) }
            surface.descriptor = descriptor
            #expect(throws: SceneFormatError.self) { try USDSceneEncoder(encoding: .usdz).encodeScene(source) }
        }
        surface.descriptor = original
        #expect(throws: SceneFormatError.self) { try USDSceneEncoder().encodeScene(source) }
    }
}
