import Testing
import SceneCore
import SceneFormats
import SceneGraph
import SceneUSD

@Suite struct USDNodeOpacityTests {
    private func geometry() -> Geometry {
        Geometry(mesh: MeshBuffer(vertexCount: 3, streams: [
            VertexStream(semantic: .position, vectors: [SIMD3<Float>(0,0,0), SIMD3(1,0,0), SIMD3(0,1,0)]),
            VertexStream(semantic: .textureCoordinate(0), vectors: [SIMD2<Float>(0,0), SIMD2(1,0), SIMD2(0,1)])
        ], submeshes: [Submesh(range: 0..<3, materialIndex: 0)]), materials: [Material()])
    }

    private func shaders(_ scene: Scene, package: Bool = false) throws -> [USDPrim] {
        let bytes = try USDSceneEncoder(encoding: package ? .usdz : .usda).encodeScene(scene)
        let stage = package ? try USDStage(archive: USDZArchive(bytes)) : try USDStage(usda: bytes)
        return stage.traverse().filter { $0.name == "Shader" }
    }

    @Test func inheritedOpacityDoesNotMutateSharedMaterials() throws {
        let geometry = geometry()
        let first = Node(geometry: geometry), second = Node(geometry: geometry)
        first.opacity = 0.5
        let scene = Scene { first; second }
        scene.rootNode.opacity = 0.5
        let values = try shaders(scene).map { $0[property: "inputs:opacity"]?.value }
        #expect(values == [.number("0.25"), .number("0.5")])
        #expect(geometry.materials[0].descriptor == .default)
        #expect(first.opacity == 0.5)
        let restored = try USDSceneDecoder().decodeScene(USDSceneEncoder().encodeScene(scene))
        #expect(try shaders(restored).map { $0[property: "inputs:opacity"]?.value } == values)
    }

    @Test(arguments: [MaterialDescriptor.AlphaMode.legacy, .blend, .opaque, .mask(cutoff: 0.2)])
    func alphaModesMatchRenderer(mode: MaterialDescriptor.AlphaMode) throws {
        let geometry = geometry()
        geometry.materials[0].descriptor.alphaMode = mode
        geometry.materials[0].descriptor.diffuse = .color(SIMD4(1,1,1,0.5))
        geometry.materials[0].descriptor.transparency = 0.5
        let node = Node(geometry: geometry)
        node.opacity = 0.5
        let shader = try #require(shaders(Scene { node }).first)
        // Opaque surfaces ignore alpha; masked surfaces apply the cutoff after multiplication.
        #expect(shader[property: "inputs:opacity"]?.value == .number(mode == .opaque ? "1.0" : "0.125"))
        #expect(shader[property: "inputs:opacityThreshold"]?.value == .number(mode == .mask(cutoff: 0.2) ? "0.2" : "0.0"))
    }

    @Test func texturedAlphaUsesInheritedOpacity() throws {
        let geometry = geometry()
        geometry.materials[0].descriptor.diffuse = .texture(.image(
            ImageBuffer(width: 1, height: 1, format: .rgba8, pixels: [255,255,255,128])))
        geometry.materials[0].descriptor.diffuseFactor.w = 0.5
        let node = Node(geometry: geometry)
        node.opacity = 0.5
        let bytes = try USDSceneEncoder(encoding: .usdz).encodeScene(Scene { node })
        let stage = try USDStage(archive: USDZArchive(bytes))
        let texture = try #require(stage.traverse().first { $0.name == "DiffuseTexture" })
        #expect(texture[property: "inputs:scale"]?.value == .tuple([
            .number("1.0"), .number("1.0"), .number("1.0"), .number("0.25")
        ]))
        let restored = try USDSceneDecoder().decodeScene(bytes)
        var alpha: Float?
        restored.rootNode.enumerateHierarchy { node, _ in
            if let material = node.geometry?.materials.first { alpha = material.descriptor.diffuseFactor.w }
        }
        #expect(alpha == 0.25)
    }

    @Test func zeroOpacityOmitsSubtreeAndGeometryOnlyIgnoresOpacity() throws {
        let node = Node(geometry: geometry())
        node.opacity = 0
        node.addChild(Node(geometry: geometry()))
        let scene = Scene { node }
        let stage = try USDStage(usda: USDSceneEncoder().encodeScene(scene))
        #expect(!stage.traverse().contains { $0.typeName == "Mesh" })
        let stripped = try USDStage(usda: USDSceneEncoder(geometryOnly: true).encodeScene(scene))
        #expect(stripped.traverse().filter { $0.typeName == "Mesh" }.count == 2)
        #expect(!stripped.traverse().contains { $0.typeName == "Material" })
        for value in [Float(-0.1), 1.1, .nan, .infinity] {
            node.opacity = value
            #expect(throws: SceneFormatError.self) { try USDSceneEncoder().encodeScene(scene) }
        }
    }
}
