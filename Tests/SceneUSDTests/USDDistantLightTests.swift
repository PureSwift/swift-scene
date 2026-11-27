import Testing
import SceneCore
import SceneFormats
import SceneGraph
import SceneUSD

@Suite struct USDDistantLightTests {
    private func lightNode(_ scene: Scene) throws -> Node {
        var result: Node?
        scene.rootNode.enumerateHierarchy { node, _ in if node.light != nil { result = node } }
        return try #require(result)
    }

    @Test(arguments: [Float(0), 2500, 50000])
    func directionalRoundTrip(strength: Float) throws {
        let node = Node()
        node.light = Light(LightDescriptor(kind: .directional, color: SIMD3(0.25,0.5,1), intensity: strength))
        node.light?.name = "Key"
        node.eulerAngles = SIMD3(0.2,0.3,0)
        let scene = Scene { node }
        for encoding in [USDSceneEncoder.Encoding.usda, .usdz] {
            let bytes = try USDSceneEncoder(encoding: encoding).encodeScene(scene)
            let restored = try USDSceneDecoder().decodeScene(bytes)
            let actual = try lightNode(restored)
            let light = try #require(actual.light)
            #expect(light.kind == .directional)
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
        def DistantLight "Sun" {
            float inputs:angle = 0
            bool inputs:shadow:enable = false
            float inputs:intensity = 2
            float inputs:exposure = 3
        }
        """.utf8)
        let scene = try USDSceneDecoder().decodeScene(bytes)
        #expect(try lightNode(scene).light?.intensity == 16000)
        let stripped = try USDStage(usda: USDSceneEncoder(geometryOnly: true).encodeScene(scene))
        #expect(!stripped.traverse().contains { $0.typeName == "DistantLight" })
        let ignored = try USDSceneDecoder(geometryOnly: true).decodeScene(bytes)
        var hasLight = false
        ignored.rootNode.enumerateHierarchy { node, _ in if node.light != nil { hasLight = true } }
        #expect(!hasLight)
    }

    @Test func rejectsUnsupportedLightFeatures() throws {
        for attribute in [
            "float inputs:angle = 1", "bool inputs:shadow:enable = true",
            "bool inputs:enableColorTemperature = true", "float inputs:diffuse = 0.5",
            "float inputs:specular = 0", "float inputs:intensity = -1",
            "float inputs:exposure = 10000", "color3f inputs:color = (2,1,1)",
            "rel light:filters = </Filter>"
        ] {
            var attributes = ["float inputs:angle = 0", "bool inputs:shadow:enable = false"]
            let name = attribute.split(separator: " ")[1]
            attributes.removeAll { $0.split(separator: " ")[1] == name }
            attributes.append(attribute)
            let bytes = Array(("#usda 1.0\ndef DistantLight \"Light\" {\n" + attributes.joined(separator: "\n") + "\n}").utf8)
            #expect(throws: SceneFormatError.self) { try USDSceneDecoder().decodeScene(bytes) }
            _ = try USDSceneDecoder(geometryOnly: true).decodeScene(bytes)
        }
        let node = Node()
        let scene = Scene { node }
        for kind in [LightDescriptor.Kind.ambient, .omni, .spot] {
            node.light = Light(kind: kind)
            #expect(throws: SceneFormatError.self) { try USDSceneEncoder().encodeScene(scene) }
        }
        node.light = Light(kind: .directional)
        node.light?.castsShadow = true
        #expect(throws: SceneFormatError.self) { try USDSceneEncoder().encodeScene(scene) }
        node.light?.castsShadow = false
        node.light?.intensity = .nan
        #expect(throws: SceneFormatError.self) { try USDSceneEncoder().encodeScene(scene) }
    }
}
