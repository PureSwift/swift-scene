import Foundation
import Testing
import SceneCore
import SceneFormats
import SceneGraph
import SceneUSD

@Suite struct USDTextureExportTests {
    private let image = ImageBuffer(width: 2, height: 2, format: .rgba8,
        pixels: [255,0,0,255, 0,255,0,128, 0,0,255,64, 255,255,255,0])

    private func scene(_ material: MaterialDescriptor, uv: Bool = true) -> Scene {
        var streams = [VertexStream(semantic: .position, vectors: [SIMD3<Float>(0,0,0), SIMD3(1,0,0), SIMD3(0,1,0)])]
        if uv { streams.append(VertexStream(semantic: .textureCoordinate(0), vectors: [SIMD2<Float>(0,0), SIMD2(1,0), SIMD2(0,1)])) }
        let geometry = Geometry(mesh: MeshBuffer(vertexCount: 3, streams: streams,
            submeshes: [Submesh(range: 0..<3, materialIndex: 0)]), materials: [Material(material)])
        return Scene { Node(geometry: geometry); Node(geometry: geometry) }
    }

    private func textured() -> MaterialDescriptor {
        var material = MaterialDescriptor.physicallyBased()
        material.diffuse = .texture(.image(image))
        material.diffuseFactor = SIMD4(0.25,0.5,0.75,0.5)
        material.transparency = 0.5
        material.alphaMode = .blend
        material.diffuse.sampler.wrapS = .repeat
        material.diffuse.sampler.wrapT = .mirror
        return material
    }

    @Test func packageContainsSharedPNGAndConnectedTextureGraph() throws {
        let source = scene(textured())
        let encoder = USDSceneEncoder(encoding: .usdz)
        let bytes = try encoder.encodeScene(source)
        #expect(bytes == (try encoder.encodeScene(source)))
        let archive = try USDZArchive(bytes)
        #expect(archive.entries.map(\.path) == ["scene.usda", "textures/diffuse_0.png"])
        #expect(archive.entries.allSatisfy { $0.data.startIndex % 64 == 0 })
        let textureBytes = try #require(archive["textures/diffuse_0.png"]?.data)
        #expect(try PNGDecoder.decode(Array(textureBytes)) == image)
        let stage = try USDStage(archive: archive)
        for index in 0..<2 {
            let base = "/Scene/Root/Node_\(index)/Mesh_0/Material"
            let shader = try #require(stage.prim(at: base + "/Shader"))
            #expect(shader[property: "inputs:diffuseColor.connect"]?.value == .path(base + "/DiffuseTexture.outputs:rgb"))
            #expect(shader[property: "inputs:opacity.connect"]?.value == .path(base + "/DiffuseTexture.outputs:a"))
            let texture = try #require(stage.prim(at: base + "/DiffuseTexture"))
            #expect(texture[property: "inputs:file"]?.value == .asset("textures/diffuse_0.png"))
            #expect(texture[property: "inputs:sourceColorSpace"]?.value == .string("sRGB"))
            #expect(texture[property: "inputs:wrapS"]?.value == .string("repeat"))
            #expect(texture[property: "inputs:wrapT"]?.value == .string("mirror"))
            #expect(texture[property: "inputs:scale"]?.value == .tuple([.number("0.25"), .number("0.5"), .number("0.75"), .number("0.25")]))
            #expect(texture[property: "inputs:st.connect"]?.value == .path(base + "/UVReader.outputs:result"))
            #expect(stage.prim(at: base + "/UVReader")?[property: "inputs:varname"]?.value == .string("st"))
        }
        let mesh = try #require(stage.prim(at: "/Scene/Root/Node_0/Mesh_0"))
        #expect(mesh[property: "primvars:st"]?.value == .array([
            .tuple([.number("0.0"), .number("1.0")]), .tuple([.number("1.0"), .number("1.0")]),
            .tuple([.number("0.0"), .number("0.0")])]))
        let restored = try USDSceneDecoder().decodeScene(bytes)
        var restoredMaterials: [MaterialDescriptor] = []
        restored.rootNode.enumerateHierarchy { node, _ in
            if let material = node.geometry?.materials.first { restoredMaterials.append(material.descriptor) }
        }
        #expect(restoredMaterials.count == 2)
        #expect(restoredMaterials.allSatisfy { $0.diffuse.contents == .texture(.image(image)) })
        #expect(restoredMaterials.allSatisfy { $0.diffuseFactor == SIMD4(0.25,0.5,0.75,0.25) })
        #expect(restoredMaterials.allSatisfy { $0.alphaMode == .blend && $0.diffuse.sampler.wrapS == .repeat && $0.diffuse.sampler.wrapT == .mirror })
        _ = try USDSceneDecoder(geometryOnly: true).decodeScene(bytes)
    }

    @Test func alphaModesAndExplicitGeometryOnly() throws {
        for mode in [MaterialDescriptor.AlphaMode.opaque, .mask(cutoff: 0.4), .legacy] {
            var material = textured()
            material.alphaMode = mode
            let archive = try USDZArchive(USDSceneEncoder(encoding: .usdz).encodeScene(scene(material)))
            let stage = try USDStage(archive: archive)
            let shader = try #require(stage.prim(at: "/Scene/Root/Node_0/Mesh_0/Material/Shader"))
            if mode == .opaque {
                #expect(shader[property: "inputs:opacity.connect"] == nil)
                #expect(shader[property: "inputs:opacity"]?.value == .number("1.0"))
            } else {
                #expect(shader[property: "inputs:opacity.connect"] != nil)
            }
            if case .mask = mode { #expect(shader[property: "inputs:opacityThreshold"]?.value == .number("0.4")) }
        }
        let stripped = try USDZArchive(USDSceneEncoder(encoding: .usdz, geometryOnly: true).encodeScene(scene(textured())))
        #expect(stripped.entries.count == 1)
        #expect(try !USDSceneEncoder(geometryOnly: true).encodeScene(scene(textured())).isEmpty)
    }

    @Test func rejectsUnrepresentableTextures() throws {
        let original = textured()
        #expect(throws: SceneFormatError.self) { try USDSceneEncoder().encodeScene(scene(original)) }
        #expect(throws: SceneFormatError.self) { try USDSceneEncoder(encoding: .usdz).encodeScene(scene(original, uv: false)) }
        var variants: [MaterialDescriptor] = []
        var invalid = original
        invalid.diffuse.mappingChannel = 1; variants.append(invalid)
        invalid = original; invalid.diffuse.intensity = -0.5; variants.append(invalid)
        invalid = original; invalid.diffuse.contentsTransform[0,0] = 2; variants.append(invalid)
        invalid = original; invalid.diffuse.sampler.magnificationFilter = .nearest; variants.append(invalid)
        invalid = original; invalid.diffuse.sampler.maxAnisotropy = 4; variants.append(invalid)
        invalid = original; invalid.diffuse.sampler.mipFilter = .nearest; variants.append(invalid)
        invalid = original; invalid.diffuse = .texture(.path("missing.png")); variants.append(invalid)
        invalid = original; invalid.lightingModel = .unlit; variants.append(invalid)
        invalid = original; invalid.transparent = .texture(.image(image)); variants.append(invalid)
        var malformed = image
        malformed.bytesPerRow = 1
        invalid = original; invalid.diffuse = .texture(.image(malformed)); variants.append(invalid)
        for material in variants {
            #expect(throws: SceneFormatError.self) { try USDSceneEncoder(encoding: .usdz).encodeScene(scene(material)) }
        }
    }

    @Test func localPNGTextureIsLoadedAndPackaged() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("diffuse.png")
        try Data(PNGEncoder.encode(image)).write(to: url)
        var material = textured()
        material.diffuse.contents = .texture(.path(url.path))
        let archive = try USDZArchive(USDSceneEncoder(encoding: .usdz).encodeScene(scene(material)))
        let entry = try #require(archive["textures/diffuse_0.png"])
        #expect(try PNGDecoder.decode(Array(entry.data)) == image)
    }
}
