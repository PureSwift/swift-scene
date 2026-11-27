import Foundation
import Testing
import SceneCore
import SceneFormats
import SceneGraph
import SceneUSD

@Suite struct USDNormalTextureTests {
    private let image = ImageBuffer(width: 1, height: 2, format: .rgba8, pixels: [160,192,224,0, 96,32,240,255])

    private func scene(strength: Float = 1) -> Scene {
        var descriptor = MaterialDescriptor.physicallyBased()
        descriptor.normal = .texture(.image(image))
        descriptor.normal.intensity = strength
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

    @Test(arguments: [Float(0), 0.5, 1, 2]) func strengthAndNormalDirectionRoundTrip(strength: Float) throws {
        let source = scene(strength: strength)
        let encoder = USDSceneEncoder(encoding: .usdz)
        let bytes = try encoder.encodeScene(source)
        let archive = try USDZArchive(bytes)
        let stage = try USDStage(archive: archive)
        let base = "/Scene/Root/Node_0/Mesh_0/Material"
        #expect(stage.prim(at: base + "/Shader")?[property: "inputs:normal.connect"]?.value == .path(base + "/NormalTexture.outputs:rgb"))
        let texture = try #require(stage.prim(at: base + "/NormalTexture"))
        #expect(texture[property: "inputs:sourceColorSpace"]?.value == .string("raw"))
        func floats(_ name: String) throws -> [Float] {
            guard case .tuple(let values) = texture[property: name]?.value else { throw SceneFormatError.unsupported("Missing tuple") }
            return try values.map { value in
                guard case .number(let text) = value, let number = Float(text) else { throw SceneFormatError.unsupported("Missing number") }
                return number
            }
        }
        let scale = try floats("inputs:scale"), bias = try floats("inputs:bias")
        #expect(scale == [2*strength, -2*strength, 2, 1])
        #expect(bias == [-strength, strength, -1, 0])
        // For this +X/+Y plane, flipping V negates the derived bitangent.
        // Compare world normals after applying the authored shader values.
        for offset in stride(from: 0, to: image.pixels.count, by: 4) {
            let p = SIMD3(Float(image.pixels[offset]), Float(image.pixels[offset+1]), Float(image.pixels[offset+2])) / 255
            let engine = SIMD3((2*p.x-1)*strength, (2*p.y-1)*strength, 2*p.z-1).normalized
            let usd = SIMD3(p.x*scale[0]+bias[0], -(p.y*scale[1]+bias[1]), p.z*scale[2]+bias[2]).normalized
            #expect((engine - usd).length < 0.00001)
        }
        let restoredScene = try USDSceneDecoder().decodeScene(bytes)
        let restored = try material(restoredScene).descriptor
        #expect(restored.normal.contents == .texture(.image(image)))
        #expect(restored.normal.intensity == strength)
        #expect(restored.alphaMode == .opaque)
        let again = try USDSceneDecoder().decodeScene(encoder.encodeScene(restoredScene))
        #expect(try material(again).descriptor == restored)
        let glb = try GLBEncoder().encodeScene(restoredScene)
        let gltf = try GLTFDecoder().decodeScene(glb)
        #expect(try material(gltf).normal.intensity == strength)
        #expect(try material(gltf).normal.contents == .texture(.image(image)))
    }

    @Test func standardUSDNormalDecodingConvertsGreenChannel() throws {
        let archive = try USDZArchive(USDSceneEncoder(encoding: .usdz).encodeScene(scene()))
        let layer = try #require(archive.defaultLayer)
        let standard = String(decoding: layer.data, as: UTF8.self)
            .replacingOccurrences(of: "(2.0, -2.0, 2.0, 1.0)", with: "(2, 2, 2, 1)")
            .replacingOccurrences(of: "(-1.0, 1.0, -1.0, 0.0)", with: "(-1, -1, -1, 0)")
        let bytes = try USDZArchive(entries: [.init(path: "scene.usda", data: Array(standard.utf8))] + archive.entries.dropFirst()).encoded()
        let restored = try material(USDSceneDecoder().decodeScene(bytes)).descriptor
        guard case .texture(.image(let converted)) = restored.normal.contents else { Issue.record("Missing normal image"); return }
        #expect(converted.pixels == [160,63,224,0, 96,223,240,255])
        #expect(restored.normal.intensity == 1)
    }

    @Test func rejectsUnsupportedNormalMaps() throws {
        for strength in [Float(-1), .nan, .infinity, .greatestFiniteMagnitude] {
            #expect(throws: SceneFormatError.self) { try USDSceneEncoder(encoding: .usdz).encodeScene(scene(strength: strength)) }
        }
        for strength in [Float(-1), .nan, .infinity] {
            #expect(throws: SceneFormatError.self) { try GLBEncoder().encodeScene(scene(strength: strength)) }
        }
        #expect(throws: SceneFormatError.self) { try USDSceneEncoder().encodeScene(scene()) }
        let archive = try USDZArchive(USDSceneEncoder(encoding: .usdz).encodeScene(scene()))
        let layer = try #require(archive.defaultLayer)
        for (old, new) in [
            ("\"raw\"", "\"sRGB\""),
            ("(2.0, -2.0, 2.0, 1.0)", "(2, -1, 2, 1)"),
            ("(-1.0, 1.0, -1.0, 0.0)", "(0, 0, 0, 0)"),
            ("texCoord2f[] primvars:st", "texCoord2f[] unused")
        ] {
            let text = String(decoding: layer.data, as: UTF8.self).replacingOccurrences(of: old, with: new)
            let bytes = try USDZArchive(entries: [.init(path: "scene.usda", data: Array(text.utf8))] + archive.entries.dropFirst()).encoded()
            #expect(throws: SceneFormatError.self) { try USDSceneDecoder().decodeScene(bytes) }
            _ = try USDSceneDecoder(geometryOnly: true).decodeScene(bytes)
        }
    }
}
