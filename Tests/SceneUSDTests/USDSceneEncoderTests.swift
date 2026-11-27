import Foundation
import Testing
import SceneCore
import SceneFormats
import SceneGraph
import SceneUSD

@Suite struct USDSceneEncoderTests {
    private func triangle(indexed: Bool = true) -> Geometry {
        Geometry(mesh: MeshBuffer(vertexCount: 3, streams: [
            VertexStream(semantic: .position, vectors: [SIMD3<Float>(0,0,0), SIMD3(1,0,0), SIMD3(0,1,0)]),
            VertexStream(semantic: .normal, vectors: Array(repeating: SIMD3<Float>(0,0,1), count: 3)),
            VertexStream(semantic: .textureCoordinate(0), vectors: [SIMD2<Float>(0,0), SIMD2(1,0), SIMD2(0,1)])
        ], indices: indexed ? IndexBuffer([0,1,2]) : nil,
        submeshes: [Submesh(range: 0..<3, materialIndex: 0, name: "Surface")]))
    }

    private func meshes(_ scene: Scene) -> [Node] {
        var result: [Node] = []
        scene.rootNode.enumerateHierarchy { node, _ in if node.geometry != nil { result.append(node) } }
        return result
    }

    @Test func deterministicUSDAAndUSDZRoundTrip() throws {
        let node = Node(name: "模型 \"quoted\"\\name\n", geometry: triangle())
        node.position = SIMD3(1,2,3)
        let scene = Scene { node }
        scene.rootNode.position = SIMD3(4,0,0)
        for encoding in [USDSceneEncoder.Encoding.usda, .usdz] {
            let encoder = USDSceneEncoder(encoding: encoding)
            let data = try encoder.encodeScene(scene)
            #expect(data == (try encoder.encodeScene(scene)))
            let stage: USDStage
            if encoding == .usdz {
                let archive = try USDZArchive(data)
                #expect(archive.entries.map(\.path) == ["scene.usda"])
                #expect(archive.entries[0].data.startIndex % 64 == 0)
                stage = try USDStage(archive: archive)
            } else { stage = try USDStage(usda: data) }
            #expect(stage.defaultPrim?.name == "Scene")
            #expect(stage.metadata["metersPerUnit"] == .number("1"))
            #expect(stage.prim(at: "/Scene/Root/Node_0")?.metadata["displayName"] == .string(node.name ?? ""))
            let restored = try USDSceneDecoder().decodeScene(data)
            let mesh = try #require(meshes(restored).first)
            #expect(mesh.geometry?.mesh.vertexCount == 3)
            #expect(mesh.worldPosition == SIMD3(5,2,3))
            #expect(mesh.parent?.name == node.name)
            #expect(mesh.name == "Surface")
            #expect(mesh.geometry?.mesh.stream(.textureCoordinate(0))?.data == [0,0,1,0,0,1])
            #expect(mesh.geometry?.mesh.stream(.normal)?.data == [0,0,1,0,0,1,0,0,1])
        }
    }

    @Test func submeshesStripsAndNonindexedGeometry() throws {
        let strip = Geometry(mesh: MeshBuffer(vertexCount: 4,
            streams: [VertexStream(semantic: .position, vectors: [SIMD3<Float>(0,0,0), SIMD3(1,0,0), SIMD3(0,1,0), SIMD3(1,1,0)])],
            indices: IndexBuffer([0,1,2,3]),
            submeshes: [Submesh(primitive: .triangleStrip, range: 0..<4, materialIndex: 0),
                        Submesh(range: 0..<3, materialIndex: 1)]),
            materials: [Material(), Material()])
        strip.materials[1].isDoubleSided = true
        let scene = Scene { Node(geometry: strip); Node(geometry: triangle(indexed: false)) }
        let restored = try USDSceneDecoder().decodeScene(USDSceneEncoder().encodeScene(scene))
        let nodes = meshes(restored)
        #expect(nodes.map { $0.geometry?.mesh.vertexCount } == [6,3,3])
        #expect(nodes[1].geometry?.materials[0].isDoubleSided == true)
        let positions = try #require(nodes[0].geometry?.mesh.positions)
        for i in stride(from: 0, to: positions.count, by: 3) {
            #expect((positions[i+1]-positions[i]).cross(positions[i+2]-positions[i]).z > 0)
        }
    }

    @Test func affinePivotsAndCollidingNames() throws {
        let matrix = Matrix4x4(SIMD4(-1,0,0,0), SIMD4(0.5,1,0,0), SIMD4(0,0,1,0), SIMD4(4,5,6,1))
        let node = Node(name: "same", geometry: triangle())
        node.pivot = try #require(matrix.inverse)
        let scene = Scene { node; Node(name: "same", geometry: triangle()) }
        let data = try USDSceneEncoder().encodeScene(scene)
        let stage = try USDStage(usda: data)
        #expect(stage.prim(at: "/Scene/Root/Node_0") != nil)
        #expect(stage.prim(at: "/Scene/Root/Node_1") != nil)
        let restored = try USDSceneDecoder().decodeScene(data)
        let transform = try #require(meshes(restored).first?.worldTransform)
        #expect((transform.transformPoint(SIMD3(1,2,3)) - SIMD3(4,7,9)).length < 0.0001)
    }

    @Test func visibilityEmptyScenesAndDegenerateStripTriangles() throws {
        let hidden = Node(geometry: triangle())
        hidden.isHidden = true
        let scene = Scene { hidden; Node(geometry: Geometry(mesh: .empty)) }
        #expect(try meshes(USDSceneDecoder().decodeScene(USDSceneEncoder().encodeScene(scene))).isEmpty)
        scene.rootNode.isHidden = true
        let stage = try USDStage(usda: USDSceneEncoder().encodeScene(scene))
        #expect(stage.defaultPrim?.children.isEmpty == true)
        let geometry = triangle()
        var mesh = geometry.mesh
        mesh.indices = IndexBuffer([0,0,1,2])
        mesh.submeshes = [Submesh(primitive: .triangleStrip, range: 0..<4, materialIndex: 0)]
        geometry.source = .mesh(mesh)
        let restored = try USDSceneDecoder().decodeScene(USDSceneEncoder().encodeScene(Scene { Node(geometry: geometry) }))
        #expect(meshes(restored).first?.geometry?.mesh.vertexCount == 3)
    }

    @Test func unsupportedAppearanceRequiresExplicitOptIn() throws {
        let geometry = triangle()
        geometry.materials[0].diffuse = .color(SIMD4(1,0,0,1))
        let scene = Scene { Node(geometry: geometry) }
        #expect(throws: SceneFormatError.self) { try USDSceneEncoder().encodeScene(scene) }
        #expect(try !USDSceneEncoder(geometryOnly: true).encodeScene(scene).isEmpty)
        geometry.materials = [Material()]
        scene.rootNode.opacity = 0.5
        #expect(throws: SceneFormatError.self) { try USDSceneEncoder().encodeScene(scene) }
        scene.rootNode.opacity = 1
        scene.rootNode.camera = Camera()
        #expect(throws: SceneFormatError.self) { try USDSceneEncoder().encodeScene(scene) }
        #expect(try !USDSceneEncoder(geometryOnly: true).encodeScene(scene).isEmpty)
    }

    @Test func rejectsMalformedGeometryAndUnrepresentableNames() throws {
        let source = triangle().mesh
        var variants: [MeshBuffer] = []
        var invalid = source
        invalid.indices = IndexBuffer([0,1,3]); variants.append(invalid)
        invalid = source; invalid.submeshes[0].range = 0..<4; variants.append(invalid)
        invalid = source; invalid.submeshes[0].range = 0..<2; variants.append(invalid)
        invalid = source; invalid.submeshes[0].materialIndex = -1; variants.append(invalid)
        invalid = source; invalid.streams[0].data[0] = .nan; variants.append(invalid)
        invalid = source; invalid.streams[0].componentCount = 0; variants.append(invalid)
        invalid = source; invalid.streams.append(source.streams[0]); variants.append(invalid)
        invalid = source; invalid.submeshes[0].primitive = .lines; variants.append(invalid)
        for mesh in variants {
            let scene = Scene { Node(geometry: Geometry(mesh: mesh)) }
            #expect(throws: SceneFormatError.self) { try USDSceneEncoder().encodeScene(scene) }
        }
        #expect(throws: SceneFormatError.self) { try USDSceneEncoder().encodeScene(Scene { Node(name: "bad\u{0}") }) }
        let scene = Scene()
        var parent = scene.rootNode
        for _ in 0..<30 { let child = Node(); parent.addChild(child); parent = child }
        #expect(throws: SceneFormatError.self) { try USDSceneEncoder().encodeScene(scene) }
    }

    @Test func legacyFileConversionWritesUSDWithoutClobberingOnFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("legacy.3dmf")
        let geometry = triangle()
        geometry.materials[0].diffuse = .color(SIMD4(1,0,0,1))
        let scene = Scene { Node(geometry: geometry) }
        try Data(ThreeDMFEncoder().encodeScene(scene)).write(to: input)
        for ext in ["usda", "USD", "usdz"] {
            let output = directory.appendingPathComponent("converted." + ext)
            let encoders = USDSceneEncoder(geometryOnly: true).fileEncoders
            try SceneAssetConverter.convert(from: input, to: output, geometryOnly: true, encoders: encoders)
            let original = try Data(contentsOf: output)
            let restored = try USDSceneDecoder().decodeScene(Array(original))
            #expect(meshes(restored).first?.geometry?.mesh.vertexCount == 3)
            #expect(throws: SceneFormatError.self) {
                try SceneAssetConverter.convert(from: input, to: output, encoders: encoders)
            }
            #expect(throws: SceneFormatError.self) {
                try SceneAssetConverter.convert(from: input, to: output, overwrite: true, encoders: USDSceneEncoder().fileEncoders)
            }
            #expect(try Data(contentsOf: output) == original)
            try SceneAssetConverter.convert(from: input, to: output, overwrite: true, encoders: encoders)
            #expect(try Data(contentsOf: output) == original)
        }
    }
}
