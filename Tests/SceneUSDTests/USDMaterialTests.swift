import Foundation
import Testing
import SceneCore
import SceneFormats
import SceneGraph
import SceneUSD

@Suite struct USDMaterialTests {
    @Test func openUSDAuthoredMaterialFixture() throws {
        let url = try #require(Bundle.module.url(forResource: "preview-surface", withExtension: "usda", subdirectory: "Fixtures"))
        let bytes = Array(try Data(contentsOf: url))
        let scene = try USDSceneDecoder().decodeScene(bytes)
        let material = try #require(materials(scene).first)
        #expect(material.diffuse.color == SIMD4(0.25,0.5,0.75,1))
        #expect(material.metalness.contents == .scalar(0.5))
        #expect(material.roughness.contents == .scalar(0.25))
        let reloaded = try USDSceneDecoder().decodeScene(USDSceneEncoder(encoding: .usdz).encodeScene(scene))
        #expect(materials(reloaded) == [material])
    }

    private let mesh = """
    point3f[] points = [(0,0,0), (1,0,0), (0,1,0)]
    int[] faceVertexCounts = [3]
    int[] faceVertexIndices = [0,1,2]
    uniform token subdivisionScheme = "none"
    """

    private func data(inputs: String = "", binding: String = "rel material:binding = </M>",
                      connection: String = "token outputs:surface.connect = </M/S.outputs:surface>",
                      metadata: String = "") -> [UInt8] {
        Array("""
        #usda 1.0
        def Mesh "Triangle" { \(mesh) \(binding) }
        def Material "M" (\(metadata)) {
            \(connection)
            def Shader "S" {
                uniform token info:id = "UsdPreviewSurface"
                token outputs:surface
                \(inputs)
            }
        }
        """.utf8)
    }

    private func materials(_ scene: Scene) -> [MaterialDescriptor] {
        var result: [MaterialDescriptor] = []
        scene.rootNode.enumerateHierarchy { node, _ in
            if let material = node.geometry?.materials.first { result.append(material.descriptor) }
        }
        return result
    }

    @Test func defaultsAndConstantAlphaModes() throws {
        let defaults = try #require(materials(USDSceneDecoder().decodeScene(data())).first)
        #expect(defaults.lightingModel == .physicallyBased)
        #expect(defaults.diffuse.color == SIMD4(0.18,0.18,0.18,1))
        #expect(defaults.roughness.contents == .scalar(0.5))
        #expect(defaults.metalness.contents == .scalar(0))
        #expect(defaults.alphaMode == .opaque)
        for (inputs, mode) in [
            ("float inputs:opacity = 0.3", MaterialDescriptor.AlphaMode.blend),
            ("float inputs:opacity = 0.3 float inputs:opacityThreshold = 0.4", .mask(cutoff: 0.4))
        ] {
            let material = try #require(materials(USDSceneDecoder().decodeScene(data(inputs: inputs))).first)
            #expect(material.alphaMode == mode)
            #expect(material.diffuse.color?.w == 0.3)
        }
    }

    @Test func inheritedBindingsOverridesAndPerMeshSidedness() throws {
        let bytes = Array("""
        #usda 1.0
        def Xform "Parent" {
            rel material:binding = </Red>
            def Mesh "A" { \(mesh) bool doubleSided = true }
            def Mesh "B" { \(mesh) rel material:binding = [</Green>] }
            def Mesh "C" { \(mesh) }
        }
        def Material "Red" {
            token outputs:surface.connect = [</Red/S.outputs:surface>]
            def Shader "S" { uniform token info:id = "UsdPreviewSurface" color3f inputs:diffuseColor = (1,0,0) }
        }
        def Material "Green" {
            token outputs:surface.connect = </Green/S.outputs:surface>
            def Shader "S" { uniform token info:id = "UsdPreviewSurface" color3f inputs:diffuseColor = (0,1,0) }
        }
        """.utf8)
        let decoded = try materials(USDSceneDecoder().decodeScene(bytes))
        #expect(decoded.map { $0.diffuse.color } == [SIMD4(1,0,0,1), SIMD4(0,1,0,1), SIMD4(1,0,0,1)])
        #expect(decoded.map(\.isDoubleSided) == [true,false,false])
        let stripped = try materials(USDSceneDecoder(geometryOnly: true).decodeScene(bytes))
        #expect(stripped.allSatisfy { $0.diffuse.color == SIMD4(1,1,1,1) })
    }

    @Test func unlitExportRoundTrip() throws {
        let material = Material(.unlit(color: SIMD4(0.2,0.4,0.8,0.5)))
        let geometry = Geometry(mesh: MeshBuffer(vertexCount: 3,
            streams: [VertexStream(semantic: .position, vectors: [SIMD3<Float>(0,0,0), SIMD3(1,0,0), SIMD3(0,1,0)])],
            submeshes: [Submesh(range: 0..<3, materialIndex: 0)]), materials: [material])
        let source = Scene { Node(geometry: geometry) }
        let bytes = try USDSceneEncoder(encoding: .usdz).encodeScene(source)
        let result = try #require(materials(USDSceneDecoder().decodeScene(bytes)).first)
        #expect(result.lightingModel == .unlit)
        #expect(result.diffuse.color == SIMD4(0.2,0.4,0.8,0.5))
        #expect(result.alphaMode == .blend)
    }

    @Test func rejectsBrokenBindingsAndUnsupportedNetworks() throws {
        let invalid = [
            data(binding: "rel material:binding = </Missing>"),
            data(binding: "rel material:binding = </M/S>"),
            data(binding: "rel material:binding = <M>"),
            data(binding: "rel material:binding = []"),
            data(binding: "rel material:binding = </M> (bindMaterialAs = \"strongerThanDescendants\")"),
            data(binding: "rel material:binding:preview = </M>"),
            data(connection: "token outputs:surface.connect = </M.outputs:surface>"),
            data(connection: "token outputs:surface.connect = </M/S.outputs:displacement>"),
            data(metadata: "active = false"),
            data(inputs: "color3f inputs:diffuseColor.connect = </Texture.outputs:rgb>"),
            data(inputs: "float inputs:metallic = 2"),
            data(inputs: "float inputs:roughness = nan"),
            data(inputs: "color3f inputs:diffuseColor = (-1,0,0)"),
            data(inputs: "float inputs:opacity = -0.1"),
            data(inputs: "float inputs:clearcoat = 1"),
            data(inputs: "int inputs:useSpecularWorkflow = 1"),
            data(inputs: "float inputs:ior = 2"),
            data(inputs: "normal3f inputs:normal = (1,0,0)"),
            data(inputs: "float inputs:displacement = 1"),
            data(inputs: "float inputs:occlusion = 0.5"),
            data(inputs: "string inputs:roughness = \"bad\"")
        ]
        for bytes in invalid {
            #expect(throws: SceneFormatError.self) { try USDSceneDecoder().decodeScene(bytes) }
            #expect(try materials(USDSceneDecoder(geometryOnly: true).decodeScene(bytes)).count == 1)
        }
    }
}
