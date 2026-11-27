import Testing
import SceneCore
import SceneFormats
import SceneGraph
import SceneUSD

@Suite struct USDIntensityTests {
    private let image = ImageBuffer(width: 1, height: 1, format: .rgba8, pixels: [128,64,32,128])

    private func scene(textured: Bool, intensity: Float) -> Scene {
        var descriptor = MaterialDescriptor.physicallyBased(baseColor: SIMD4(1,1,1,0.5))
        if textured { descriptor.diffuse = .texture(.image(image)) }
        descriptor.diffuse.intensity = intensity
        descriptor.diffuseFactor = SIMD4(0.25,0.5,0.125,0.5)
        descriptor.emission = .color(SIMD4(2,1,0.5,1))
        descriptor.emission.intensity = intensity
        descriptor.emissionFactor = SIMD3(1,2,4)
        descriptor.alphaMode = .blend
        let geometry = Geometry(mesh: MeshBuffer(vertexCount: 3, streams: [
            VertexStream(semantic: .position, vectors: [SIMD3<Float>(0,0,0), SIMD3(1,0,0), SIMD3(0,1,0)]),
            VertexStream(semantic: .textureCoordinate(0), vectors: [SIMD2<Float>(0,0), SIMD2(1,0), SIMD2(0,1)])
        ], submeshes: [Submesh(range: 0..<3, materialIndex: 0)]), materials: [Material(descriptor)])
        return Scene { Node(geometry: geometry) }
    }

    private func material(_ scene: Scene) throws -> MaterialDescriptor {
        var result: MaterialDescriptor?
        scene.rootNode.enumerateHierarchy { node, _ in
            if let material = node.geometry?.materials.first { result = material.descriptor }
        }
        return try #require(result)
    }

    @Test(arguments: [Float(0), 0.5, 1, 2])
    func intensityBakesIntoRGBWithoutChangingAlpha(intensity: Float) throws {
        for textured in [false, true] {
            let source = scene(textured: textured, intensity: intensity)
            let encoder = USDSceneEncoder(encoding: textured ? .usdz : .usda)
            let restoredScene = try USDSceneDecoder().decodeScene(encoder.encodeScene(source))
            let restored = try material(restoredScene)
            let expected = SIMD3<Float>(0.25,0.5,0.125) * intensity
            if textured {
                #expect(restored.diffuse.contents == .texture(.image(image)))
                #expect(restored.diffuseFactor == SIMD4(expected.x, expected.y, expected.z, 0.5))
            } else {
                #expect(restored.diffuse.color == SIMD4(expected.x, expected.y, expected.z, 0.25))
            }
            #expect(restored.diffuse.intensity == 1)
            #expect(restored.emission.color == SIMD4(2*intensity, 2*intensity, 2*intensity, 1))
            #expect(restored.emission.intensity == 1)
            #expect(try material(source).diffuse.intensity == intensity)
            let again = try USDSceneDecoder().decodeScene(encoder.encodeScene(restoredScene))
            #expect(try material(again) == restored)
        }
    }

    @Test func rejectsInvalidIntensityAndDiffuseOverflow() throws {
        for value in [Float(-1), .nan, .infinity, 3] {
            for textured in [false, true] {
                #expect(throws: SceneFormatError.self) {
                    try USDSceneEncoder(encoding: .usdz).encodeScene(scene(textured: textured, intensity: value))
                }
            }
        }
        let source = scene(textured: false, intensity: 1)
        let surface = try #require(source.rootNode.children.first?.geometry?.materials.first)
        surface.descriptor.emission.intensity = .greatestFiniteMagnitude
        #expect(throws: SceneFormatError.self) { try USDSceneEncoder().encodeScene(source) }
        surface.descriptor.emission = .texture(.image(image))
        surface.descriptor.emission.intensity = 0.5
        #expect(throws: SceneFormatError.self) { try USDSceneEncoder(encoding: .usdz).encodeScene(source) }
    }
}
