import Foundation
import Testing
import SceneCore
import SceneFormats
import SceneGraph
@testable import SceneUSD

@Suite struct USDSceneDecoderTests {
    private let triangle = """
    point3f[] points = [(0,0,0), (1,0,0), (0,1,0)]
    int[] faceVertexCounts = [3]
    int[] faceVertexIndices = [0,1,2]
    uniform token subdivisionScheme = "none"
    """

    private func decode(_ body: String, metadata: String = "metersPerUnit = 1", geometryOnly: Bool = false) throws -> Scene {
        try USDSceneDecoder(geometryOnly: geometryOnly).decodeScene(Array(("#usda 1.0\n(\(metadata))\n" + body).utf8))
    }

    private func expectNear(_ a: SIMD3<Float>, _ b: SIMD3<Float>, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect((a - b).length < 0.0001, sourceLocation: sourceLocation)
    }

    @Test func fixtureAndPackagedMeshBecomeGeometry() throws {
        let url = try #require(Bundle.module.url(forResource: "triangle", withExtension: "usda", subdirectory: "Fixtures"))
        let bytes = Array(try Data(contentsOf: url))
        #expect(throws: SceneFormatError.self) { try USDSceneDecoder().decodeScene(bytes) }
        let package = try USDZArchive(entries: [.init(path: "scene.usda", data: bytes)]).encoded()
        for data in [bytes, package] {
            let scene = try USDSceneDecoder(geometryOnly: true).decodeScene(data)
            let world = try #require(scene.rootNode.children.first)
            let node = try #require(world.children.first)
            let mesh = try #require(node.geometry?.mesh)
            #expect(world.name == "World")
            #expect(world.children.count == 1) // Material explicitly discarded.
            #expect(mesh.vertexCount == 3)
            expectNear(node.worldTransform.transformPoint(.zero), SIMD3(1,2,3))
            #expect(mesh.bounds.min == .zero)
            #expect(mesh.bounds.max == SIMD3(1,1,0))
            #expect(mesh.stream(.normal)?.data == [0,0,1, 0,0,1, 0,0,1])
            #expect(mesh.stream(.textureCoordinate(0))?.data == [0,1, 1,1, 0,0])
        }
    }

    @Test func transformsUseUSDOrderDegreesAndInversePivots() throws {
        let scene = try decode("""
        def Xform "World" {
            double3 xformOp:translate = (10,0,0)
            double3 xformOp:translate:pivot = (1,0,0)
            float xformOp:rotateZ = 90
            float3 xformOp:scale = (2,2,2)
            uniform token[] xformOpOrder = ["xformOp:translate", "xformOp:translate:pivot", "xformOp:rotateZ", "xformOp:scale", "!invert!xformOp:translate:pivot"]
            def Xform "Reset" {
                double3 xformOp:translate = (0,3,0)
                uniform token[] xformOpOrder = ["!resetXformStack!", "xformOp:translate"]
            }
        }
        """)
        let world = try #require(scene.rootNode.children.first)
        expectNear(world.worldTransform.transformPoint(SIMD3(2,0,0)), SIMD3(11,2,0))
        let reset = try #require(world.children.first)
        expectNear(reset.worldPosition, SIMD3(0,3,0))
    }

    @Test func matrixShearReflectionAndOrientationArePreserved() throws {
        let scene = try decode("""
        def Xform "Matrix" {
            matrix4d xformOp:transform = ((-1,0,0,0), (0.5,1,0,0), (0,0,1,0), (4,5,6,1))
            uniform token[] xformOpOrder = ["xformOp:transform"]
        }
        def Xform "Rotation" {
            quatf xformOp:orient = (0,0,0,1)
            uniform token[] xformOpOrder = ["xformOp:orient"]
        }
        def Xform "Euler" {
            float3 xformOp:rotateXYZ = (90,90,0)
            uniform token[] xformOpOrder = ["xformOp:rotateXYZ"]
        }
        """)
        expectNear(scene.rootNode.children[0].worldTransform.transformPoint(SIMD3(1,2,3)), SIMD3(4,7,9))
        expectNear(scene.rootNode.children[1].worldTransform.transformDirection(SIMD3(1,0,0)), SIMD3(-1,0,0))
        expectNear(scene.rootNode.children[2].worldTransform.transformDirection(SIMD3(0,1,0)), SIMD3(1,0,0))
    }

    @Test func stageUnitsUpAxisVisibilityAndActive() throws {
        let scene = try decode("""
        def Xform "Hidden" {
            token visibility = "invisible"
            double3 xformOp:translate = (0,0,100)
            uniform token[] xformOpOrder = ["xformOp:translate"]
        }
        def Mesh "Inactive" (active = false) {}
        """, metadata: "metersPerUnit = 0.01 upAxis = \"Z\"")
        #expect(scene.rootNode.children.count == 1)
        #expect(scene.rootNode.children[0].isHidden)
        expectNear(scene.rootNode.children[0].worldPosition, SIMD3(0,1,0))
        let fallback = try decode("def Xform \"World\" {}", metadata: "")
        #expect(fallback.rootNode.scale == SIMD3(repeating: 0.01))
    }

    @Test func polygonsHolesAndFaceVaryingUVs() throws {
        let scene = try decode("""
        def Mesh "Mesh" {
            point3f[] points = [(0,0,0), (2,0,0), (2,2,0), (1,1,0), (0,2,0)]
            int[] faceVertexCounts = [5,3]
            int[] faceVertexIndices = [0,1,2,3,4, 0,1,3]
            int[] holeIndices = [1]
            uniform token subdivisionScheme = "none"
            uniform token orientation = "leftHanded"
            bool doubleSided = true
            texCoord2f[] primvars:st = [(0,0), (1,0), (1,1), (0.5,0.5), (0,1)] (interpolation = "faceVarying")
            int[] primvars:st:indices = [0,1,2,3,4,0,1,3]
        }
        """)
        let geometry = try #require(scene.rootNode.children.first?.geometry)
        let mesh = geometry.mesh
        #expect(mesh.vertexCount == 9)
        #expect(geometry.materials[0].isDoubleSided)
        var area: Float = 0
        let uv = try #require(mesh.stream(.textureCoordinate(0)))
        for index in stride(from: 0, to: mesh.vertexCount, by: 3) {
            let a = mesh.positions[index], b = mesh.positions[index+1], c = mesh.positions[index+2]
            let cross = (b-a).cross(c-a)
            #expect(cross.z < 0)
            area += cross.length / 2
        }
        #expect(abs(area - 3) < 0.0001)
        for (index, point) in mesh.positions.enumerated() {
            #expect(abs(uv.data[index*2] - point.x / 2) < 0.0001)
            #expect(abs(uv.data[index*2+1] - (1-point.y/2)) < 0.0001)
        }
        #expect(mesh.stream(.normal)?.data.enumerated().allSatisfy { $0.offset % 3 == 2 ? $0.element == -1 : $0.element == 0 } == true)
    }

    @Test func normalInterpolationModes() throws {
        for (mode, values) in [("constant", "[(0,0,1)]"), ("uniform", "[(0,0,1)]"),
                               ("vertex", "[(0,0,1),(0,0,1),(0,0,1)]"),
                               ("varying", "[(0,0,1),(0,0,1),(0,0,1)]"),
                               ("faceVarying", "[(0,0,1),(0,0,1),(0,0,1)]")] {
            let scene = try decode("def Mesh \"Mesh\" {\(triangle)\nnormal3f[] normals = \(values) (interpolation = \"\(mode)\")}")
            #expect(scene.rootNode.children[0].geometry?.mesh.stream(.normal)?.data == [0,0,1,0,0,1,0,0,1])
        }
    }

    @Test func importedGeometryExportsToGLB() throws {
        let scene = try decode("""
        def Xform "World" {
            double3 xformOp:translate = (1,2,3)
            uniform token[] xformOpOrder = ["xformOp:translate"]
            def Mesh "Triangle" {\(triangle)}
        }
        """)
        let exported = try GLBEncoder().encodeScene(scene)
        let restored = try GLTFDecoder().decodeScene(exported)
        var meshes: [Node] = []
        restored.rootNode.enumerateHierarchy { node, _ in
            if node.geometry != nil { meshes.append(node) }
        }
        #expect(meshes.count == 1)
        let mesh = try #require(meshes.first)
        expectNear(mesh.worldPosition, SIMD3(1,2,3))
        #expect(mesh.geometry?.mesh.vertexCount == 3)
    }

    @Test func malformedTopologyAndUnsupportedFeaturesThrow() throws {
        let badMeshes = [
            triangle.replacingOccurrences(of: "[0,1,2]", with: "[0,1,3]"),
            triangle.replacingOccurrences(of: "[3]", with: "[9223372036854775807]"),
            triangle.replacingOccurrences(of: "[3]", with: "[2]"),
            triangle.replacingOccurrences(of: "\"none\"", with: "\"catmullClark\""),
            triangle + "\nint[] holeIndices = [-1]",
            triangle + "\nnormal3f[] normals = [(0,0,1)]",
            triangle + "\ntexCoord2f[] primvars:st = [(0,0)] int[] primvars:st:indices = [-1]",
            triangle + "\nfloat[] points = []",
            triangle.replacingOccurrences(of: "(1,0,0)", with: "(inf,0,0)")
        ]
        for mesh in badMeshes {
            #expect(throws: SceneFormatError.self) { try decode("def Mesh \"Mesh\" {\(mesh)}") }
        }
        for body in [
            "def Sphere \"Sphere\" {}", "def Xform \"X\" (instanceable = true) {}",
            "def Xform \"X\" { token[] xformOpOrder = [\"xformOp:translate\"] }",
            "def Xform \"X\" { float3 xformOp:scale = (0,1,1) token[] xformOpOrder = [\"!invert!xformOp:scale\"] }",
            "def Xform \"X\" { float3[] primvars:color = [(1,1,1)] }",
            "def Xform \"X\" { rel skel:skeleton = </Skeleton> }"
        ] { #expect(throws: SceneFormatError.self) { try decode(body) } }
        #expect(throws: SceneFormatError.self) { try decode("", metadata: "metersPerUnit = -1") }
        #expect(throws: SceneFormatError.self) { try decode("", metadata: "upAxis = \"X\"") }
    }
}
