import Foundation
import Testing
import SceneCore
import SceneFormats
import SceneGraph
import SceneUSD

@Suite struct USDTextureImportTests {
    private let image = ImageBuffer(width: 1, height: 2, format: .rgba8, pixels: [255,0,0,64, 0,0,255,128])

    private func package(mode: MaterialDescriptor.AlphaMode = .blend) throws -> USDZArchive {
        var material = MaterialDescriptor.physicallyBased()
        material.diffuse = .texture(.image(image))
        material.alphaMode = mode
        material.diffuseFactor = SIMD4(0.5,0.75,1,0.5)
        let geometry = Geometry(mesh: MeshBuffer(vertexCount: 3, streams: [
            VertexStream(semantic: .position, vectors: [SIMD3<Float>(0,0,0), SIMD3(1,0,0), SIMD3(0,1,0)]),
            VertexStream(semantic: .textureCoordinate(0), vectors: [SIMD2<Float>(0,0), SIMD2(1,0), SIMD2(0,1)])
        ], submeshes: [Submesh(range: 0..<3, materialIndex: 0)]), materials: [Material(material)])
        return try USDZArchive(USDSceneEncoder(encoding: .usdz).encodeScene(Scene { Node(geometry: geometry) }))
    }

    private func modified(_ archive: USDZArchive, replacing old: String, with new: String,
                          layerPath: String = "scene.usda", images: Bool = true) throws -> [UInt8] {
        let source = try #require(archive.defaultLayer)
        let text = String(decoding: source.data, as: UTF8.self).replacingOccurrences(of: old, with: new)
        var entries = [USDZArchive.Entry(path: layerPath, data: Array(text.utf8))]
        if images { entries += archive.entries.dropFirst() }
        return try USDZArchive(entries: entries).encoded()
    }

    private func material(_ bytes: [UInt8]) throws -> MaterialDescriptor {
        let scene = try USDSceneDecoder().decodeScene(bytes)
        var materials: [MaterialDescriptor] = []
        scene.rootNode.enumerateHierarchy { node, _ in
            if let material = node.geometry?.materials.first { materials.append(material.descriptor) }
        }
        return try #require(materials.first)
    }

    @Test func alphaMaskAndTextureRoundTrips() throws {
        for mode in [MaterialDescriptor.AlphaMode.blend, .mask(cutoff: 0.4), .opaque] {
            let archive = try package(mode: mode)
            let bytes = try archive.encoded()
            let value = try material(bytes)
            #expect(value.alphaMode == mode)
            #expect(value.diffuseFactor == SIMD4(0.5,0.75,1,mode == .opaque ? 1 : 0.5))
            guard case .texture(.image(let pixels)) = value.diffuse.contents else {
                Issue.record("Expected embedded image"); continue
            }
            #expect(pixels.pixels == (mode == .opaque ? [255,0,0,255,0,0,255,255] : image.pixels))
            let scene = try USDSceneDecoder().decodeScene(bytes)
            let second = try material(USDSceneEncoder(encoding: .usdz).encodeScene(scene))
            #expect(second == value)
        }
    }

    @Test func constantOpacityDoesNotMultiplyImageAlpha() throws {
        let archive = try package()
        let bytes = try modified(archive,
            replacing: "float inputs:opacity.connect = </Scene/Root/Node_0/Mesh_0/Material/DiffuseTexture.outputs:a>",
            with: "float inputs:opacity = 0.25")
        let value = try material(bytes)
        #expect(value.alphaMode == .blend)
        #expect(value.diffuseFactor.w == 0.25)
        guard case .texture(.image(let pixels)) = value.diffuse.contents else { Issue.record("Expected texture"); return }
        #expect(pixels.pixels == [255,0,0,255,0,0,255,255])
    }

    @Test func nestedLayerResolvesOnlyPackageMembers() throws {
        let archive = try package()
        let bytes = try modified(archive, replacing: "@textures/diffuse_0.png@", with: "@../textures/./diffuse_0.png@",
                                 layerPath: "layers/root.usda")
        #expect(try material(bytes).diffuse.contents == .texture(.image(image)))
        for path in ["../../outside.png", "/tmp/image.png", "file:///tmp/image.png", "https://example.com/image.png", "other.usdz[image.png]", "textures//image.png"] {
            let invalid = try modified(archive, replacing: "@textures/diffuse_0.png@", with: "@\(path)@", layerPath: "layers/root.usda")
            #expect(throws: SceneFormatError.self) { try material(invalid) }
        }
    }

    @Test func rejectsUnsupportedGraphsAndMissingResources() throws {
        let archive = try package()
        for (old, new) in [
            ("\"sRGB\"", "\"raw\""),
            ("\"UsdUVTexture\"", "\"UnknownShader\""),
            ("string inputs:varname = \"st\"", "string inputs:varname = \"uv2\""),
            ("float3 outputs:rgb", "float4 inputs:bias = (0.1,0,0,0)\nfloat3 outputs:rgb"),
            ("float3 outputs:rgb", "float inputs:unknown = 1\nfloat3 outputs:rgb"),
            ("DiffuseTexture.outputs:a", "OtherTexture.outputs:a"),
            ("UVReader.outputs:result", "DiffuseTexture.outputs:rgb"),
            ("@textures/diffuse_0.png@", "@missing.png@"),
            ("texCoord2f[] primvars:st", "texCoord2f[] unused")
        ] {
            let bytes = try modified(archive, replacing: old, with: new)
            #expect(throws: SceneFormatError.self) { try material(bytes) }
            _ = try USDSceneDecoder(geometryOnly: true).decodeScene(bytes)
        }
        let missing = try modified(archive, replacing: "", with: "", images: false)
        #expect(throws: SceneFormatError.self) { try material(missing) }
        let layer = try #require(archive.defaultLayer)
        let corrupt = try USDZArchive(entries: [.init(path: "scene.usda", data: Array(layer.data)),
            .init(path: "textures/diffuse_0.png", data: [1,2,3])]).encoded()
        #expect(throws: SceneFormatError.self) { try material(corrupt) }
        #expect(throws: SceneFormatError.self) { try USDSceneDecoder().decodeScene(Array(layer.data)) }
    }
}
