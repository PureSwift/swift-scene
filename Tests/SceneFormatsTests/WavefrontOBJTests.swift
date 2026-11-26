import Testing
import SceneCore
import SceneGraph
@testable import SceneFormats

@Suite struct OBJLineReaderTests {

    @Test(arguments: [
        ("0", 0), ("1", 1), ("-2.5", -2.5), ("+.5", 0.5), ("3.", 3), ("1e3", 1000), ("-1.25E-2", -0.0125), ("0.000001", 0.000001),
    ] as [(String, Float)])
    func numbers(_ text: String, _ expected: Float) {
        #expect(OBJLineReader.parseFloat(ArraySlice(Array(text.utf8))) == expected)
    }

    @Test func notNumbers() {
        #expect(OBJLineReader.parseFloat(ArraySlice(Array("abc".utf8))) == nil)
        #expect(OBJLineReader.parseFloat(ArraySlice(Array("1e".utf8))) == nil)
    }

    @Test func commentsAndContinuations() {
        var reader = OBJLineReader(Array("# header\r\nv 1 2 \\\n 3 # trailing\n\n  \nf 1 2 3".utf8))
        let first = reader.nextLine()
        let keyword = reader.keyword()
        let numbers = reader.numbers(upTo: 4)
        #expect(first && keyword == "v")
        #expect(numbers == [1, 2, 3])
        let second = reader.nextLine()
        let face = reader.keyword()
        #expect(second && face == "f")
        let more = reader.nextLine()
        #expect(!more)
    }
}

@Suite struct WavefrontOBJTests {

    private func decode(_ text: String, materials: [String: String] = [:], strict: Bool = true) throws -> Scene {
        let decoder = WavefrontOBJDecoder(baseDirectory: "/models", isStrict: strict) { path in
            materials[path].map { Array($0.utf8) }
        }
        return try decoder.decodeScene(Array(text.utf8))
    }

    private func area(_ mesh: MeshBuffer) -> Float {
        let p = mesh.positions
        return mesh.submeshes.flatMap { mesh.triangles(in: $0) }.reduce(0) { $0 + (p[$1.y] - p[$1.x]).cross(p[$1.z] - p[$1.x]).length / 2 }
    }

    @Test func quadWithAllIndexForms() throws {
        let scene = try decode("""
        v 0 0 0
        v 1 0 0
        v 1 1 0
        v 0 1 0
        vt 0 0
        vt 1 0
        vt 1 1
        vt 0 1
        vn 0 0 1
        f 1/1/1 2/2/1 3/3/1 4/4/1
        """)
        let mesh = try #require(scene.rootNode.children.first?.geometry?.mesh)
        #expect(mesh.vertexCount == 4)
        #expect(mesh.triangles(in: mesh.submeshes[0]).count == 2)
        #expect(abs(area(mesh) - 1) < 1e-6)
        // OBJ's v runs up; ours down.
        let uvs = try #require(mesh.stream(.textureCoordinate(0)))
        #expect(Array(uvs[0]) == [0, 1])
        #expect(Array(uvs[2]) == [1, 0])
    }

    @Test func negativeIndicesAndSharedVertices() throws {
        let scene = try decode("""
        v 0 0 0
        v 1 0 0
        v 1 1 0
        v 0 1 0
        vn 0 0 1
        f -4//1 -3//1 -2//1
        f 1//1 3//1 4//1
        """)
        let mesh = try #require(scene.rootNode.children.first?.geometry?.mesh)
        // Two triangles sharing an edge: four vertices, not six.
        #expect(mesh.vertexCount == 4)
        #expect(abs(area(mesh) - 1) < 1e-6)
    }

    @Test func flatNormalsWithoutNormals() throws {
        let scene = try decode("""
        v 0 0 0
        v 1 0 0
        v 0 1 0
        v 0 0 1
        f 1 2 3
        f 1 4 2
        """)
        let mesh = try #require(scene.rootNode.children.first?.geometry?.mesh)
        // Each face keeps its own vertices so its normal is its own.
        #expect(mesh.vertexCount == 6)
        let normals = try #require(mesh.stream(.normal))
        #expect(Array(normals[0]) == [0, 0, 1])
        #expect(Array(normals[3]) == [0, 1, 0])
    }

    @Test func concavePolygon() throws {
        let scene = try decode("""
        v 0 0 0
        v 2 0 0
        v 2 1 0
        v 1 1 0
        v 1 2 0
        v 0 2 0
        f 1 2 3 4 5 6
        """)
        let mesh = try #require(scene.rootNode.children.first?.geometry?.mesh)
        #expect(abs(area(mesh) - 3) < 1e-5)
    }

    @Test func objectsGroupsAndMaterials() throws {
        let mtl = """
        newmtl red
        Kd 1 0 0
        Ks 0.5 0.5 0.5
        Ns 64
        d 0.5
        newmtl brick
        illum 1
        map_Kd -s 2 2 1 textures\\brick.png
        newmtl metal
        Kd 0.8 0.8 0.8
        Pm 1
        Pr 0.25
        """
        let scene = try decode("""
        mtllib scene.mtl
        v 0 0 0
        v 1 0 0
        v 0 1 0
        o first
        usemtl red
        f 1 2 3
        usemtl brick
        f 1 3 2
        usemtl red
        f 2 3 1
        g second
        usemtl metal
        f 1 2 3
        """, materials: ["/models/scene.mtl": mtl])
        #expect(scene.rootNode.children.map(\.name) == ["first", "second"])
        let first = try #require(scene.rootNode.children.first?.geometry)
        // Faces by material, in the order first used.
        #expect(first.mesh.submeshes.map(\.name) == ["red", "brick"])
        #expect(first.mesh.submeshes.map { $0.range.count } == [6, 3])
        let red = first.materials[0]
        #expect(red.diffuse.color == SIMD4(1, 0, 0, 1))
        #expect(red.shininess == 0.5)
        #expect(red.transparency == 0.5)
        let brick = first.materials[1]
        #expect(brick.lightingModel == .lambert)
        #expect(brick.diffuse.contents == .texture(.path("/models/textures/brick.png")))
        #expect(brick.diffuse.contentsTransform == Matrix4x4(scale: SIMD3(2, 2, 1)))
        let metal = try #require(scene.rootNode.children.last?.geometry?.firstMaterial)
        #expect(metal.lightingModel == .physicallyBased)
        #expect(metal.metalness.color?.x == 1)
        #expect(metal.roughness.color?.x == 0.25)
    }

    @Test func vertexColors() throws {
        let scene = try decode("""
        v 0 0 0 1 0 0
        v 1 0 0 0 1 0
        v 0 1 0 0 0 1
        f 1 2 3
        """)
        let geometry = try #require(scene.rootNode.children.first?.geometry)
        let colors = try #require(geometry.mesh.stream(.color))
        #expect(Array(colors[1]) == [0, 1, 0, 1])
        #expect(geometry.firstMaterial?.diffuse.color == SIMD4(1, 1, 1, 1))
    }

    @Test func badIndices() throws {
        let text = """
        v 0 0 0
        v 1 0 0
        v 0 1 0
        f 1 2 9
        f 1 2 3
        """
        #expect(throws: SceneFormatError.self) { try decode(text) }
        // Leniently, the bad face is skipped and the good one kept.
        let scene = try decode(text, strict: false)
        #expect(scene.rootNode.children.first?.geometry?.mesh.triangles(in: scene.rootNode.children.first!.geometry!.mesh.submeshes[0]).count == 1)
    }
}
