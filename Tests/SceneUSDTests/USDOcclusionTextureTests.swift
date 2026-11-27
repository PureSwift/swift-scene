import Foundation
import Testing
import SceneCore
import SceneFormats
import SceneGraph
import SceneUSD

@Suite struct USDOcclusionTextureTests {
    private let image = ImageBuffer(width: 1, height: 2, format: .rgba8, pixels: [160,192,224,0, 96,32,240,255])

    private func scene(strength: Float = 1) -> Scene {
        var descriptor = MaterialDescriptor.physicallyBased()
        descriptor.ambientOcclusion = .texture(.image(image))
        descriptor.ambientOcclusion.intensity = strength
        descriptor.metalness = .texture(.image(image))
        descriptor.roughness = descriptor.metalness
        let geometry = Geometry(mesh: MeshBuffer(vertexCount: 3, streams: [
            VertexStream(semantic: .position, vectors: [SIMD3<Float>(0,0,0), SIMD3(1,0,0), SIMD3(0,1,0)]),
            VertexStream(semantic: .normal, vectors: Array(repeating: SIMD3<Float>(0,0,1), count: 3)),
            VertexStream(semantic: .textureCoordinate(0), vectors: [SIMD2<Float>(0,0), SIMD2(1,0), SIMD2(0,1)])
        ], submeshes: [Submesh(range: 0..<3, materialIndex: 0)]), materials: [Material(descriptor)])
        return Scene { Node(geometry: geometry) }
    }

    private func material(_ scene: Scene) throws -> Material {
        var result: Material?
        scene.rootNode.enumerateHierarchy { node, _ in if let material = node.geometry?.materials.first { result = material } }
        return try #require(result)
    }

    @Test(arguments: [Float(0), 0.25, 0.5, 1]) func strengthRoundTrip(strength: Float) throws {
        let encoder = USDSceneEncoder(encoding: .usdz)
        let bytes = try encoder.encodeScene(scene(strength: strength))
        let archive = try USDZArchive(bytes)
        #expect(archive.entries.count == 2) // One image shared by occlusion and metallic/roughness.
        let stage = try USDStage(archive: archive)
        let base = "/Scene/Root/Node_0/Mesh_0/Material"
        #expect(stage.prim(at: base + "/Shader")?[property: "inputs:occlusion.connect"]?.value == .path(base + "/OcclusionTexture.outputs:r"))
        let texture = try #require(stage.prim(at: base + "/OcclusionTexture"))
        #expect(texture[property: "inputs:sourceColorSpace"]?.value == .string("raw"))
        func floats(_ name: String) throws -> [Float] {
            guard case .tuple(let values) = texture[property: name]?.value else { throw SceneFormatError.unsupported("Missing tuple") }
            return try values.map { value in
                guard case .number(let text) = value, let number = Float(text) else { throw SceneFormatError.unsupported("Missing number") }
                return number
            }
        }
        let scale = try floats("inputs:scale"), bias = try floats("inputs:bias")
        #expect(scale == [strength, 1, 1, 1])
        #expect(bias == [1-strength, 0, 0, 0])
        for red in [Float(0), 0.2, 1] {
            #expect(abs(red * scale[0] + bias[0] - (1 + strength * (red - 1))) < 0.00001)
        }
        let restoredScene = try USDSceneDecoder().decodeScene(bytes)
        let restored = try material(restoredScene).descriptor
        #expect(restored.ambientOcclusion.contents == .texture(.image(image)))
        #expect(restored.ambientOcclusion.intensity == strength)
        #expect(restored.roughness.contents == restored.ambientOcclusion.contents)
        let again = try USDSceneDecoder().decodeScene(encoder.encodeScene(restoredScene))
        #expect(try material(again).descriptor == restored)
        let gltf = try GLTFDecoder().decodeScene(GLBEncoder().encodeScene(restoredScene))
        #expect(try material(gltf).descriptor.ambientOcclusion.intensity == strength)
        #expect(try material(gltf).descriptor.ambientOcclusion.contents == .texture(.image(image)))
    }

    @Test func rejectsUnsupportedOcclusionMaps() throws {
        for strength in [Float(-1), 1.1, .nan, .infinity] {
            #expect(throws: SceneFormatError.self) { try USDSceneEncoder(encoding: .usdz).encodeScene(scene(strength: strength)) }
            #expect(throws: SceneFormatError.self) { try GLBEncoder().encodeScene(scene(strength: strength)) }
        }
        #expect(throws: SceneFormatError.self) { try USDSceneEncoder().encodeScene(scene()) }
        let archive = try USDZArchive(USDSceneEncoder(encoding: .usdz).encodeScene(scene(strength: 0.5)))
        let layer = try #require(archive.defaultLayer)
        for (old, new) in [
            ("OcclusionTexture.outputs:r", "OcclusionTexture.outputs:g"),
            ("(0.5, 0.0, 0.0, 0.0)", "(0, 0, 0, 0)"),
            ("(0.5, 1.0, 1.0, 1.0)", "(0.5, 2, 1, 1)"),
            ("\"raw\"", "\"sRGB\""),
            ("texCoord2f[] primvars:st", "texCoord2f[] unused")
        ] {
            let text = String(decoding: layer.data, as: UTF8.self).replacingOccurrences(of: old, with: new)
            #expect(text != String(decoding: layer.data, as: UTF8.self))
            let bytes = try USDZArchive(entries: [.init(path: "scene.usda", data: Array(text.utf8))] + archive.entries.dropFirst()).encoded()
            #expect(throws: SceneFormatError.self) { try USDSceneDecoder().decodeScene(bytes) }
            _ = try USDSceneDecoder(geometryOnly: true).decodeScene(bytes)
        }
    }
}
