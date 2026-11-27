import Foundation
import Testing
import SceneCore
import SceneFormats
import SceneGraph
import SceneUSD

@Suite struct USDPackedTextureTests {
    private let image = ImageBuffer(width: 2, height: 1, format: .rgba8, pixels: [5,64,192,0, 9,224,32,255])

    private func scene(sharedColorSlots: Bool = false) -> Scene {
        var descriptor = MaterialDescriptor.physicallyBased()
        descriptor.metalness = .texture(.image(image))
        descriptor.metalness.sampler.wrapS = .repeat
        descriptor.roughness = descriptor.metalness
        descriptor.metalnessFactor = 0.75
        descriptor.roughnessFactor = 0.25
        if sharedColorSlots {
            descriptor.diffuse = .texture(.image(image))
            descriptor.alphaMode = .blend
            descriptor.emission = .texture(.image(image))
        }
        let geometry = Geometry(mesh: MeshBuffer(vertexCount: 3, streams: [
            VertexStream(semantic: .position, vectors: [SIMD3<Float>(0,0,0), SIMD3(1,0,0), SIMD3(0,1,0)]),
            VertexStream(semantic: .textureCoordinate(0), vectors: [SIMD2<Float>(0,0), SIMD2(1,0), SIMD2(0,1)])
        ], submeshes: [Submesh(range: 0..<3, materialIndex: 0)]), materials: [Material(descriptor)])
        return Scene { Node(geometry: geometry) }
    }

    private func material(_ scene: Scene) throws -> Material {
        var result: Material?
        scene.rootNode.enumerateHierarchy { node, _ in if let material = node.geometry?.materials.first { result = material } }
        return try #require(result)
    }

    @Test(arguments: [false, true]) func channelsColorSpaceAndRoundTrip(sharedColorSlots: Bool) throws {
        let source = scene(sharedColorSlots: sharedColorSlots)
        let encoder = USDSceneEncoder(encoding: .usdz)
        let bytes = try encoder.encodeScene(source)
        #expect(bytes == (try encoder.encodeScene(source)))
        let archive = try USDZArchive(bytes)
        #expect(archive.entries.count == 2)
        let stage = try USDStage(archive: archive)
        let base = "/Scene/Root/Node_0/Mesh_0/Material"
        let surface = try #require(stage.prim(at: base + "/Shader"))
        #expect(surface[property: "inputs:metallic.connect"]?.value == .path(base + "/MetallicRoughnessTexture.outputs:b"))
        #expect(surface[property: "inputs:roughness.connect"]?.value == .path(base + "/MetallicRoughnessTexture.outputs:g"))
        let packed = try #require(stage.prim(at: base + "/MetallicRoughnessTexture"))
        #expect(packed[property: "inputs:sourceColorSpace"]?.value == .string("raw"))
        #expect(packed[property: "inputs:scale"]?.value == .tuple([.number("1.0"), .number("0.25"), .number("0.75"), .number("1.0")]))
        #expect(stage.traverse().filter { $0.name == "UVReader" }.count == 1)
        if sharedColorSlots {
            #expect(stage.prim(at: base + "/DiffuseTexture")?[property: "inputs:sourceColorSpace"]?.value == .string("sRGB"))
            #expect(stage.prim(at: base + "/EmissionTexture")?[property: "inputs:sourceColorSpace"]?.value == .string("sRGB"))
        }
        let restoredScene = try USDSceneDecoder().decodeScene(bytes)
        let restored = try material(restoredScene).descriptor
        #expect(restored.metalness.contents == .texture(.image(image)))
        #expect(restored.roughness == restored.metalness)
        #expect(restored.metalnessFactor == 0.75)
        #expect(restored.roughnessFactor == 0.25)
        #expect(restored.metalness.sampler.wrapS == .repeat)
        let again = try USDSceneDecoder().decodeScene(encoder.encodeScene(restoredScene))
        #expect(try material(again).descriptor == restored)
    }

    @Test func rejectsSeparateMapsAndInvalidConnections() throws {
        let source = scene()
        #expect(throws: SceneFormatError.self) { try USDSceneEncoder().encodeScene(source) }
        let original = try material(source).descriptor
        var variants: [MaterialDescriptor] = []
        var invalid = original
        invalid.roughness = .scalar(0.5); variants.append(invalid)
        invalid = original; invalid.metalness = .scalar(0.5); variants.append(invalid)
        invalid = original; invalid.roughness.sampler.wrapS = .mirror; variants.append(invalid)
        invalid = original; invalid.lightingModel = .phong; variants.append(invalid)
        invalid = original; invalid.roughnessFactor = 2; variants.append(invalid)
        for descriptor in variants {
            try material(source).descriptor = descriptor
            #expect(throws: SceneFormatError.self) { try USDSceneEncoder(encoding: .usdz).encodeScene(source) }
        }
        let archive = try USDZArchive(USDSceneEncoder(encoding: .usdz).encodeScene(scene()))
        let layer = try #require(archive.defaultLayer)
        for (old, new) in [
            ("\"raw\"", "\"sRGB\""),
            ("MetallicRoughnessTexture.outputs:g", "MetallicRoughnessTexture.outputs:r"),
            ("MetallicRoughnessTexture.outputs:b", "OtherTexture.outputs:b"),
            ("inputs:metallic.connect", "inputs:unused.connect"),
            ("(1.0, 0.25, 0.75, 1.0)", "(1, 2, 0.75, 1)")
        ] {
            let text = String(decoding: layer.data, as: UTF8.self).replacingOccurrences(of: old, with: new)
            let bytes = try USDZArchive(entries: [.init(path: "scene.usda", data: Array(text.utf8))] + archive.entries.dropFirst()).encoded()
            #expect(throws: SceneFormatError.self) { try USDSceneDecoder().decodeScene(bytes) }
            _ = try USDSceneDecoder(geometryOnly: true).decodeScene(bytes)
        }
    }
}
