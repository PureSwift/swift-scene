import Testing
import SceneCore
import SceneFormats
import SceneGraph
import SceneUSD

@Suite struct USDPointLightTests {
    private func lightNode(_ scene: Scene) throws -> Node {
        var result: Node?
        scene.rootNode.enumerateHierarchy { node, _ in if node.light != nil { result = node } }
        return try #require(result)
    }

    @Test(arguments: [Float(0), 2500, 50000])
    func pointRoundTrip(strength: Float) throws {
        let node = Node()
        node.light = Light(LightDescriptor(kind: .omni, color: SIMD3(0.25,0.5,1), intensity: strength, falloffModel: .inverseSquare))
        node.light?.name = "Key"
        node.position = SIMD3(2,3,4)
        let scene = Scene { node }
        for encoding in [USDSceneEncoder.Encoding.usda, .usdz] {
            let bytes = try USDSceneEncoder(encoding: encoding).encodeScene(scene)
            let restored = try USDSceneDecoder().decodeScene(bytes)
            let actual = try lightNode(restored)
            let light = try #require(actual.light)
            #expect(light.kind == .omni)
            #expect(light.name == "Key")
            #expect(light.intensity == strength)
            #expect(light.color == SIMD3(0.25,0.5,1))
            #expect(!light.castsShadow)
            for (a,b) in zip(actual.worldTransform.columnMajorElements, node.worldTransform.columnMajorElements) {
                #expect(abs(a-b) < 0.00001)
            }
            let again = try USDSceneDecoder().decodeScene(USDSceneEncoder().encodeScene(restored))
            #expect(try lightNode(again).light?.descriptor == light.descriptor)
            let gltf = try GLTFDecoder().decodeScene(GLBEncoder().encodeScene(restored))
            #expect(try lightNode(gltf).light?.descriptor == light.descriptor)
        }
    }

    @Test func exposureAndGeometryOnly() throws {
        let bytes = Array("""
        #usda 1.0
        def SphereLight "Sun" {
            bool treatAsPoint = true
            bool inputs:normalize = true
            float inputs:radius = 0
            bool inputs:shadow:enable = false
            float inputs:intensity = 2
            float inputs:exposure = 3
        }
        """.utf8)
        let scene = try USDSceneDecoder().decodeScene(bytes)
        #expect(try lightNode(scene).light?.intensity == 16000)
        let stripped = try USDStage(usda: USDSceneEncoder(geometryOnly: true).encodeScene(scene))
        #expect(!stripped.traverse().contains { $0.typeName == "SphereLight" })
        let ignored = try USDSceneDecoder(geometryOnly: true).decodeScene(bytes)
        var hasLight = false
        ignored.rootNode.enumerateHierarchy { node, _ in if node.light != nil { hasLight = true } }
        #expect(!hasLight)
    }

    @Test func rejectsAreaLightsAndLegacyFalloff() throws {
        let valid = ["bool treatAsPoint = true", "bool inputs:normalize = true",
                     "float inputs:radius = 0", "bool inputs:shadow:enable = false"]
        for attribute in ["bool treatAsPoint = false", "bool inputs:normalize = false",
                          "float inputs:radius = 1", "float inputs:radius = -1",
                          "bool inputs:shadow:enable = true", "float inputs:shaping:cone:angle = 30"] {
            let name = attribute.split(separator: " ")[1]
            let attributes = valid.filter { $0.split(separator: " ")[1] != name } + [attribute]
            let bytes = Array(("#usda 1.0\ndef SphereLight \"Light\" {\n" + attributes.joined(separator: "\n") + "\n}").utf8)
            #expect(throws: SceneFormatError.self) { try USDSceneDecoder().decodeScene(bytes) }
            _ = try USDSceneDecoder(geometryOnly: true).decodeScene(bytes)
        }
        let node = Node()
        node.light = Light(kind: .omni)
        let scene = Scene { node }
        #expect(throws: SceneFormatError.self) { try USDSceneEncoder().encodeScene(scene) }
        node.light?.descriptor.falloffModel = .inverseSquare
        node.light?.attenuationEndDistance = 10
        #expect(throws: SceneFormatError.self) { try USDSceneEncoder().encodeScene(scene) }
        node.light?.attenuationEndDistance = 0
        node.light?.intensity = .infinity
        #expect(throws: SceneFormatError.self) { try USDSceneEncoder().encodeScene(scene) }
    }
}
