import Testing
import SceneCore
import SceneFormats
import SceneGraph
import SceneUSD

@Suite struct USDCameraTests {
    private func close(_ a: Matrix4x4, _ b: Matrix4x4) -> Bool {
        zip(a.columnMajorElements, b.columnMajorElements).allSatisfy { abs($0 - $1) < 0.0001 }
    }

    @Test(arguments: [false, true]) func cameraRoundTrip(orthographic: Bool) throws {
        for direction in [CameraDescriptor.ProjectionDirection.vertical, .horizontal] {
            let camera = Camera(CameraDescriptor(fieldOfView: 73, projectionDirection: direction,
                usesOrthographicProjection: orthographic, orthographicScale: 4, zNear: 0.25, zFar: 800, aspectRatio: 1.5))
            camera.name = "Lens \"A\""
            let node = Node()
            node.camera = camera
            node.position = SIMD3(2,3,4)
            node.eulerAngles = SIMD3(0.1,0.2,0.3)
            let scene = Scene { node }
            scene.rootNode.position = SIMD3(1,0,0)
            for encoding in [USDSceneEncoder.Encoding.usda, .usdz] {
                let bytes = try USDSceneEncoder(encoding: encoding).encodeScene(scene)
                let restored = try USDSceneDecoder().decodeScene(bytes)
                let actual = try #require(restored.firstCameraNode)
                let lens = try #require(actual.camera)
                #expect(lens.name == camera.name)
                #expect(close(actual.worldTransform, node.worldTransform))
                #expect(close(lens.projectionMatrix(aspectRatio: 2), camera.projectionMatrix(aspectRatio: 2)))
                #expect(abs(try #require(lens.descriptor.aspectRatio) - 1.5) < 0.00001)
                let again = try USDSceneDecoder().decodeScene(USDSceneEncoder().encodeScene(restored))
                #expect(close(try #require(again.firstCameraNode?.camera).projectionMatrix(aspectRatio: 2),
                              camera.projectionMatrix(aspectRatio: 2)))
                let gltf = try GLTFDecoder().decodeScene(GLBEncoder().encodeScene(restored))
                #expect(close(try #require(gltf.firstCameraNode?.camera).projectionMatrix(aspectRatio: 2),
                              camera.projectionMatrix(aspectRatio: 2)))
            }
        }
    }

    @Test func aspectFallbackAndGeometryOnly() throws {
        let node = Node()
        node.camera = Camera()
        let scene = Scene { node }
        #expect(throws: SceneFormatError.self) { try USDSceneEncoder().encodeScene(scene) }
        let encoder = USDSceneEncoder(cameraAspectRatio: 2)
        let encode = try #require(encoder.fileEncoders["usda"])
        let restored = try USDSceneDecoder().decodeScene(encode(scene))
        #expect(restored.firstCameraNode?.camera?.descriptor.aspectRatio == 2)
        let stripped = try USDStage(usda: USDSceneEncoder(geometryOnly: true).encodeScene(scene))
        #expect(!stripped.traverse().contains { $0.typeName == "Camera" })
        let ignored = try USDSceneDecoder(geometryOnly: true).decodeScene(encoder.encodeScene(scene))
        #expect(ignored.firstCameraNode == nil)
        for aspect in [Float(0), -1, .nan, .infinity] {
            #expect(throws: SceneFormatError.self) { try USDSceneEncoder(cameraAspectRatio: aspect).encodeScene(scene) }
        }
        node.camera?.descriptor.zFar = .infinity
        #expect(throws: SceneFormatError.self) { try encoder.encodeScene(scene) }
    }

    @Test func cameraUnitsAndAxesAreAppliedOnce() throws {
        let text = """
        #usda 1.0
        (metersPerUnit = 0.01 upAxis = "Z")
        def Camera "Lens" {
            token projection = "orthographic"
            float horizontalAperture = 400
            float verticalAperture = 200
            float2 clippingRange = (1, 1000)
            double3 xformOp:translate = (0, 0, 100)
            uniform token[] xformOpOrder = ["xformOp:translate"]
        }
        """
        let scene = try USDSceneDecoder().decodeScene(Array(text.utf8))
        let node = try #require(scene.firstCameraNode)
        let camera = try #require(node.camera)
        #expect((node.worldTransform.transformPoint(.zero) - SIMD3(0,1,0)).length < 0.00001)
        #expect(camera.orthographicScale == 10)
        #expect(camera.zNear == 1)
        #expect(camera.zFar == 1000)
        // The scaled root converts local view-space distances, including the orthographic window.
        let edge = node.worldTransform.transformPoint(SIMD3(20,10,-10))
        let view = try #require(node.worldTransform.inverse)
        let clip = camera.projectionMatrix(aspectRatio: 1).transformPoint(view.transformPoint(edge))
        #expect(abs(clip.x - 1) < 0.00001)
        #expect(abs(clip.y - 1) < 0.00001)
    }

    @Test func rejectsUnsupportedAndMalformedLenses() throws {
        for attribute in [
            "float horizontalApertureOffset = 1", "float verticalApertureOffset = 1",
            "float fStop = 2", "double shutter:close = 1", "token stereoRole = \"left\"",
            "float4[] clippingPlanes = [(1, 0, 0, 0)]", "token projection = \"fisheye\"",
            "float verticalAperture = 0", "float focalLength = 0",
            "float2 clippingRange = (2, 1)", "float2 clippingRange = (0, 1)",
            "float customLens = 1"
        ] {
            let bytes = Array(("#usda 1.0\ndef Camera \"Lens\" {\n" + attribute + "\n}").utf8)
            #expect(throws: SceneFormatError.self) { try USDSceneDecoder().decodeScene(bytes) }
            #expect(try USDSceneDecoder(geometryOnly: true).decodeScene(bytes).firstCameraNode == nil)
        }
        let defaults = try USDSceneDecoder().decodeScene(Array("#usda 1.0\ndef Camera \"Lens\" {}".utf8))
        #expect(defaults.firstCameraNode?.camera?.zFar == 1_000_000)
    }
}
