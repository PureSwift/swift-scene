import Foundation
import Testing
import SceneCore
import SceneGraph
import SceneFormats

@Suite struct GLTFEmissiveStrengthTests {
    private func scene(_ rgb: SIMD3<Float>, unlit: Bool = false) -> Scene {
        var descriptor = MaterialDescriptor.physicallyBased()
        if unlit { descriptor.lightingModel = .unlit }
        descriptor.emission = .color(SIMD4(rgb.x,rgb.y,rgb.z,1))
        let geometry = Geometry(mesh: MeshBuffer(vertexCount: 3, streams: [
            VertexStream(semantic: .position, vectors: [SIMD3<Float>(0,0,0), SIMD3(1,0,0), SIMD3(0,1,0)])
        ], submeshes: [Submesh(range: 0..<3, materialIndex: 0)]), materials: [Material(descriptor)])
        return Scene { Node(geometry: geometry) }
    }

    @Test(arguments: [Float(0), 0.5, 1, 4, 10000])
    func constantRoundTrip(strength: Float) throws {
        let color = SIMD3<Float>(1,0.5,0.25) * strength
        let bytes = try GLBEncoder().encodeScene(scene(color))
        let length = (0..<4).reduce(0) { $0 | Int(bytes[12+$1]) << (8*$1) }
        let json = try #require(JSONSerialization.jsonObject(with: Data(bytes[20..<20+length])) as? [String: Any])
        let materials = try #require(json["materials"] as? [[String: Any]])
        let material = try #require(materials.first)
        let factor = try #require(material["emissiveFactor"] as? [Double])
        #expect(factor.allSatisfy { (0...1).contains($0) })
        let extensions = material["extensions"] as? [String: Any]
        let extra = extensions?["KHR_materials_emissive_strength"] as? [String: Double]
        #expect(extra?["emissiveStrength"] == (strength > 1 ? Double(strength) : nil))
        #expect(((json["extensionsUsed"] as? [String]) ?? []).contains("KHR_materials_emissive_strength") == (strength > 1))
        let restored = try GLTFDecoder().decodeScene(bytes)
        var emission: SIMD4<Float>?
        restored.rootNode.enumerateHierarchy { node, _ in
            if let material = node.geometry?.materials.first { emission = material.emission.color }
        }
        #expect(emission == SIMD4(color.x,color.y,color.z,1))
    }

    @Test func validatesExtensionAndSupportsRequiredDeclaration() throws {
        func input(strength: String, unlit: Bool = false, factor: String = "[1,0.5,0.25]") -> [UInt8] {
            Array("""
            {"asset":{"version":"2.0"},"extensionsRequired":["KHR_materials_emissive_strength"],
            "materials":[{"emissiveFactor":\(factor),"extensions":{
            "KHR_materials_emissive_strength":{\(strength)}\(unlit ? ", \"KHR_materials_unlit\":{}" : "")
            }}]}
            """.utf8)
        }
        _ = try GLTFDecoder().decodeScene(input(strength: ""))
        _ = try GLTFDecoder().decodeScene(input(strength: "\"emissiveStrength\": 0"))
        _ = try GLTFDecoder().decodeScene(input(strength: "\"emissiveStrength\": 4"))
        #expect(throws: SceneFormatError.self) { try GLTFDecoder().decodeScene(input(strength: "\"emissiveStrength\": -1")) }
        #expect(throws: SceneFormatError.self) { try GLTFDecoder().decodeScene(input(strength: "", unlit: true)) }
        #expect(throws: SceneFormatError.self) { try GLTFDecoder().decodeScene(input(strength: "", factor: "[2,0,0]")) }
        #expect(throws: SceneFormatError.self) { try GLBEncoder().encodeScene(scene(SIMD3(2,1,0), unlit: true)) }
        #expect(throws: SceneFormatError.self) { try GLBEncoder().encodeScene(scene(SIMD3(-1,0,0))) }
    }
}
