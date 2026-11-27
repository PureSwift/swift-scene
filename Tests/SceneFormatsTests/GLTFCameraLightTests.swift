import Foundation
import Testing
import SceneCore
import SceneGraph
@testable import SceneFormats

@Suite struct GLTFCameraLightTests {
    private func json(_ object: [String: Any]) throws -> [UInt8] {
        Array(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }

    private func document(_ lights: [[String: Any]], indices: [Int] = [0]) -> [String: Any] {
        ["asset": ["version": "2.0"], "extensionsRequired": ["KHR_lights_punctual"],
         "extensions": ["KHR_lights_punctual": ["lights": lights]],
         "nodes": indices.map { ["extensions": ["KHR_lights_punctual": ["light": $0]]] }]
    }

    private func glbJSON(_ bytes: [UInt8]) throws -> [String: Any] {
        let count = (0..<4).reduce(0) { $0 | Int(bytes[12 + $1]) << ($1 * 8) }
        return try #require(JSONSerialization.jsonObject(with: Data(bytes[20..<20 + count])) as? [String: Any])
    }

    @Test func loadsPunctualLightsAndSharesInstances() throws {
        let definitions: [[String: Any]] = [
            ["type": "directional", "name": "sun", "color": [0.1, 0.2, 0.3], "intensity": 2],
            ["type": "point", "range": 12],
            ["type": "spot", "spot": [:]]
        ]
        let scene = try GLTFDecoder().decodeScene(json(document(definitions, indices: [0, 1, 2, 0])))
        let nodes = scene.rootNode.children
        #expect(nodes.count == 4)
        let sun = try #require(nodes[0].light)
        #expect(sun === nodes[3].light)
        #expect(sun.name == "sun")
        #expect(sun.kind == .directional)
        #expect(sun.intensity == 2000)
        #expect(sun.descriptor.radiance == SIMD3(0.2, 0.4, 0.6))
        #expect(nodes[1].light?.descriptor.falloffModel == .inverseSquare)
        #expect(nodes[1].light?.attenuationEndDistance == 12)
        #expect(nodes[2].light?.spotInnerAngle == 0)
        #expect(abs((nodes[2].light?.spotOuterAngle ?? 0) - 90) < 0.001)
    }

    @Test func roundTripsLightsAndExtensionDeclarations() throws {
        let source = Scene()
        let parent = Node(name: "parent")
        parent.position = [1, 2, 3]
        source.rootNode.addChild(parent)
        for (index, kind) in [LightDescriptor.Kind.directional, .omni, .spot].enumerated() {
            let node = Node(name: "light\(index)")
            node.position = [0, 0, 2]
            node.eulerAngles = [0.2, 0.3, 0.4]
            node.light = Light(LightDescriptor(kind: kind, color: [0.4, 0.5, 0.6], intensity: 2300,
                attenuationEndDistance: kind == .directional ? 0 : 8,
                spotInnerAngle: 20, spotOuterAngle: 60, falloffModel: .inverseSquare))
            node.light?.name = "fixture\(index)"
            parent.addChild(node)
        }
        let mesh = Node(geometry: .box())
        mesh.geometry?.firstMaterial = Material(.unlit(color: [1, 0, 0, 1]))
        parent.addChild(mesh)
        let bytes = try GLBEncoder().encodeScene(source)
        let object = try glbJSON(bytes)
        #expect(object["extensionsUsed"] as? [String] == ["KHR_materials_unlit", "KHR_lights_punctual"])
        let decoded = try GLTFDecoder().decodeScene(bytes)
        for index in 0..<3 {
            let node = try #require(decoded.rootNode.childNode(named: "light\(index)"))
            let original = try #require(parent.childNode(named: "light\(index)"))
            #expect(node.worldPosition == original.worldPosition)
            let matrixDelta = zip(node.transform.columnMajorElements, original.transform.columnMajorElements).map { abs($0 - $1) }
            #expect(matrixDelta.allSatisfy { $0 < 0.00001 })
            #expect(node.light?.name == "fixture\(index)")
            #expect(node.light?.kind == original.light?.kind)
            #expect(abs((node.light?.intensity ?? 0) - 2300) < 0.001)
            #expect(node.light?.attenuationEndDistance == original.light?.attenuationEndDistance)
        }
        let spot = try #require(decoded.rootNode.childNode(named: "light2")?.light)
        #expect(abs(spot.spotInnerAngle - 20) < 0.001)
        #expect(abs(spot.spotOuterAngle - 60) < 0.001)
        let omitted = try GLTFDecoder().decodeScene(GLBEncoder(omitCamerasAndLights: true).encodeScene(source))
        #expect(omitted.rootNode.childNodes { $0.light != nil }.isEmpty)
    }

    @Test func cameraProjectionRoundTrips() throws {
        let source = Scene()
        let cameras = [
            CameraDescriptor(fieldOfView: 70, zNear: 0.2, zFar: 300),
            CameraDescriptor(fieldOfView: 80, projectionDirection: .horizontal, zNear: 0.1, zFar: .infinity, aspectRatio: 2),
            CameraDescriptor(usesOrthographicProjection: true, orthographicScale: 3, zNear: 0, zFar: 80, aspectRatio: 1.5)
        ]
        for (i, descriptor) in cameras.enumerated() {
            let node = Node(name: "camera\(i)")
            node.camera = Camera(descriptor)
            node.camera?.name = "lens\(i)"
            node.position = [1, 2, 3]
            source.rootNode.addChild(node)
        }
        let bytes = try GLBEncoder().encodeScene(source)
        let object = try glbJSON(bytes)
        let definitions = try #require(object["cameras"] as? [[String: Any]])
        let infinite = try #require(definitions[1]["perspective"] as? [String: Any])
        #expect(infinite["zfar"] == nil)
        let decoded = try GLTFDecoder().decodeScene(bytes)
        for (i, original) in cameras.enumerated() {
            let node = try #require(decoded.rootNode.childNode(named: "camera\(i)"))
            let camera = try #require(node.camera)
            #expect(camera.name == "lens\(i)")
            #expect(node.position == SIMD3(1, 2, 3))
            let expected = original.projectionMatrix(aspectRatio: 1.7).columnMajorElements
            let actual = camera.projectionMatrix(aspectRatio: 1.7).columnMajorElements
            #expect(actual.allSatisfy { $0.isFinite })
            #expect(zip(expected, actual).allSatisfy { abs($0 - $1) < 0.00001 })
        }
        #expect(decoded.rootNode.childNode(named: "camera1")?.camera?.zFar == .infinity)
        let projection = cameras[1].projectionMatrix(aspectRatio: 2)
        #expect(projection[2, 2] == -1)
        #expect(projection[2, 3] == -0.2)
        let frustum = Frustum(viewProjection: projection)
        #expect(frustum.contains(SIMD3(0, 0, -1_000_000)))
        #expect(!frustum.contains(SIMD3(0, 0, -0.05)))
    }

    @Test func missingCameraAspectRequiresExplicitViewport() throws {
        for descriptor in [CameraDescriptor(projectionDirection: .horizontal), CameraDescriptor(usesOrthographicProjection: true)] {
            let scene = Scene()
            scene.rootNode.camera = Camera(descriptor)
            #expect(throws: SceneFormatError.self) { try GLBEncoder().encodeScene(scene) }
            let decoded = try GLTFDecoder().decodeScene(GLBEncoder(cameraAspectRatio: 1.75).encodeScene(scene))
            let actual = try #require(decoded.rootNode.children.first?.camera)
            let expected = descriptor.projectionMatrix(aspectRatio: 1.75).columnMajorElements
            #expect(zip(expected, actual.projectionMatrix(aspectRatio: 1).columnMajorElements).allSatisfy { abs($0 - $1) < 0.00001 })
            #expect(throws: SceneFormatError.self) { try GLBEncoder(cameraAspectRatio: .nan).encodeScene(scene) }
        }
    }

    @Test func rejectsMalformedLightDocuments() throws {
        let invalid: [[String: Any]] = [
            ["type": "ambient"], ["type": "point", "color": [1, 1]],
            ["type": "point", "color": [1, -1, 1]], ["type": "point", "color": [1, 2, 1]],
            ["type": "point", "intensity": -1], ["type": "point", "intensity": 1e38],
            ["type": "point", "range": 0], ["type": "directional", "range": 5],
            ["type": "spot"], ["type": "point", "spot": [:]],
            ["type": "spot", "spot": ["innerConeAngle": -0.1]],
            ["type": "spot", "spot": ["innerConeAngle": 1, "outerConeAngle": 1]],
            ["type": "spot", "spot": ["outerConeAngle": 2]]
        ]
        for light in invalid {
            #expect(throws: SceneFormatError.self) { try GLTFDecoder().decodeScene(json(document([light]))) }
        }
        for index in [-1, 1] {
            #expect(throws: SceneFormatError.self) { try GLTFDecoder().decodeScene(json(document([["type": "point"]], indices: [index]))) }
        }
    }

    @Test func rejectsMalformedCamerasAndUnsupportedLightSettings() throws {
        let invalid: [[String: Any]] = [
            ["type": "perspective", "perspective": ["yfov": 1, "znear": 0]],
            ["type": "perspective", "perspective": ["yfov": 1, "znear": 1, "aspectRatio": 0]],
            ["type": "perspective", "perspective": ["yfov": 1, "znear": 1, "zfar": 0.5]],
            ["type": "orthographic", "orthographic": ["xmag": 1, "ymag": 1, "znear": -1, "zfar": 5]]
        ]
        for camera in invalid {
            #expect(throws: SceneFormatError.self) {
                try GLTFDecoder().decodeScene(json(["asset": ["version": "2.0"], "nodes": [["camera": 0]], "cameras": [camera]]))
            }
        }
        let scene = Scene()
        scene.rootNode.light = Light(kind: .ambient)
        #expect(throws: SceneFormatError.self) { try GLBEncoder().encodeScene(scene) }
        scene.rootNode.light = Light(LightDescriptor(castsShadow: true))
        #expect(throws: SceneFormatError.self) { try GLBEncoder().encodeScene(scene) }
        scene.rootNode.light = Light(LightDescriptor(temperature: 3000))
        #expect(throws: SceneFormatError.self) { try GLBEncoder().encodeScene(scene) }
        #expect(throws: Never.self) { try GLBEncoder(omitCamerasAndLights: true).encodeScene(scene) }
    }

    @Test func scnConversionPreservesCameraAndLightWithoutOmission() throws {
        let fixture = try #require(Bundle.module.url(forResource: "reference", withExtension: "scn", subdirectory: "Fixtures"))
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".glb")
        defer { try? FileManager.default.removeItem(at: destination) }
        try SceneAssetConverter.convert(from: fixture, to: destination)
        let decoded = try SceneAssetFile(url: destination).load()
        #expect(decoded.rootNode.childNodes { $0.camera != nil }.count == 1)
        #expect(decoded.rootNode.childNodes { $0.light != nil }.count == 1)
    }
}
