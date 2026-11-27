import Foundation
import Testing
import SceneCore
import SceneFormats
import SceneGraph
import SceneUSD

@Suite struct USDEmissionTextureTests {
    private let image = ImageBuffer(width: 1, height: 2, format: .rgba8, pixels: [255,0,0,0, 0,0,255,128])

    private func scene(sharedDiffuse: Bool = false) -> Scene {
        var descriptor = MaterialDescriptor.physicallyBased(baseColor: SIMD4(0.25,0.5,0.75,1))
        descriptor.emission = .texture(.image(image))
        descriptor.emissionFactor = SIMD3(4,2,0.5)
        descriptor.emission.sampler.wrapS = .mirror
        if sharedDiffuse {
            descriptor.diffuse = .texture(.image(image))
            descriptor.diffuse.sampler.wrapS = .repeat
            descriptor.alphaMode = .blend
            descriptor.diffuseFactor.w = 0.5
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

    @Test(arguments: [false, true]) func emissiveImageRoundTrip(sharedDiffuse: Bool) throws {
        let source = scene(sharedDiffuse: sharedDiffuse)
        let encoder = USDSceneEncoder(encoding: .usdz)
        let bytes = try encoder.encodeScene(source)
        #expect(bytes == (try encoder.encodeScene(source)))
        let archive = try USDZArchive(bytes)
        #expect(archive.entries.count == 2) // The same image is shared across slots.
        let stage = try USDStage(archive: archive)
        let base = "/Scene/Root/Node_0/Mesh_0/Material"
        let shader = try #require(stage.prim(at: base + "/Shader"))
        #expect(shader[property: "inputs:emissiveColor.connect"]?.value == .path(base + "/EmissionTexture.outputs:rgb"))
        let texture = try #require(stage.prim(at: base + "/EmissionTexture"))
        #expect(texture[property: "inputs:scale"]?.value == .tuple([.number("4.0"), .number("2.0"), .number("0.5"), .number("1.0")]))
        #expect(stage.traverse().filter { $0.name == "UVReader" }.count == 1)
        let decoded = try USDSceneDecoder().decodeScene(bytes)
        let restored = try material(decoded).descriptor
        #expect(restored.emission.contents == .texture(.image(image)))
        #expect(restored.emissionFactor == SIMD3(4,2,0.5))
        #expect(restored.emission.sampler.wrapS == .mirror)
        #expect(restored.alphaMode == (sharedDiffuse ? .blend : .opaque))
        if sharedDiffuse {
            #expect(restored.diffuse.sampler.wrapS == .repeat)
            #expect(restored.diffuseFactor.w == 0.5)
        } else { #expect(restored.diffuse.color == SIMD4(0.25,0.5,0.75,1)) }
        let glb = try GLBEncoder().encodeScene(decoded)
        let gltf = try GLTFDecoder().decodeScene(glb)
        #expect(try material(gltf).descriptor.emissionFactor == restored.emissionFactor)
        #expect(try material(gltf).descriptor.emission.contents == restored.emission.contents)
        let again = try USDSceneDecoder().decodeScene(encoder.encodeScene(decoded))
        #expect(try material(again).descriptor == restored)
    }

    @Test func rejectsUnsupportedEmissionTextures() throws {
        let source = scene()
        #expect(throws: SceneFormatError.self) { try USDSceneEncoder().encodeScene(source) }
        let surface = try material(source)
        var descriptor = surface.descriptor
        descriptor.lightingModel = .unlit
        surface.descriptor = descriptor
        #expect(throws: SceneFormatError.self) { try USDSceneEncoder(encoding: .usdz).encodeScene(source) }
        descriptor.lightingModel = .physicallyBased
        descriptor.emissionFactor.x = .infinity
        surface.descriptor = descriptor
        #expect(throws: SceneFormatError.self) { try USDSceneEncoder(encoding: .usdz).encodeScene(source) }
        let archive = try USDZArchive(USDSceneEncoder(encoding: .usdz).encodeScene(scene()))
        let layer = try #require(archive.defaultLayer)
        for replacement in ["(-1, 2, 0.5, 1)", "(nan, 2, 0.5, 1)"] {
            let text = String(decoding: layer.data, as: UTF8.self).replacingOccurrences(of: "(4.0, 2.0, 0.5, 1.0)", with: replacement)
            let invalid = try USDZArchive(entries: [.init(path: "scene.usda", data: Array(text.utf8))] + archive.entries.dropFirst()).encoded()
            #expect(throws: SceneFormatError.self) { try USDSceneDecoder().decodeScene(invalid) }
        }
        let stripped = try USDZArchive(USDSceneEncoder(encoding: .usdz, geometryOnly: true).encodeScene(source))
        #expect(stripped.entries.count == 1)
    }
}
