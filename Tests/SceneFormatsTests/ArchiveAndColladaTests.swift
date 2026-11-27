import Foundation
import Testing
import SceneCore
import SceneGraph
@testable import SceneFormats

@Suite struct ArchiveAndColladaTests {
    @Test func sceneKitReferenceArchive() throws {
        let url = try #require(Bundle.module.url(forResource: "reference", withExtension: "scn", subdirectory: "Fixtures"))
        let bytes = [UInt8](try Data(contentsOf: url))
        let scene = try SCNArchiveDecoder().decodeScene(bytes)
        let triangle = try #require(scene.rootNode.childNode(named: "triangle"))
        #expect(triangle.geometry?.mesh.vertexCount == 3)
        #expect(triangle.worldPosition == SIMD3<Float>(1, 2, 3))
        #expect(scene.rootNode.childNodes { $0.camera != nil }.count == 1)
        #expect(scene.rootNode.childNodes { $0.light != nil }.count == 1)
        let material = try #require(triangle.geometry?.materials.first)
        #expect(material.descriptor.name == "red")
        #expect(material.descriptor.diffuse == .color(SIMD4(1, 0, 0, 1)))
        for count in stride(from: 0, to: bytes.count, by: 37) {
            #expect(throws: SceneFormatError.self) { try SCNArchiveDecoder().decodeScene(Array(bytes.prefix(count))) }
        }
    }

    @Test func jpegAndArchivedTextureResources() throws {
        let jpegURL = try #require(Bundle.module.url(forResource: "red", withExtension: "jpg", subdirectory: "Fixtures"))
        let bytes = [UInt8](try Data(contentsOf: jpegURL))
        let image = try TextureImageLoader.decodeImage(bytes)
        #expect(image.width == 8 && image.height == 8)
        #expect(image.pixels[0] > 240 && image.pixels[1] < 10 && image.pixels[2] < 10)
        #expect(TextureImageLoader.decode(Array(bytes.prefix(20))) == nil)
        let archiveURL = try #require(Bundle.module.url(forResource: "shapes", withExtension: "scn", subdirectory: "Fixtures"))
        var paths: [String] = []
        let scene = try SCNArchiveDecoder(resourceLoader: { path in paths.append(path); return bytes })
            .decodeScene([UInt8](try Data(contentsOf: archiveURL)))
        let shapes = scene.rootNode.childNodes { $0.geometry != nil }
        #expect(shapes.count == 6 && paths.count == 6)
        #expect(paths.allSatisfy { $0 == "checker.png" })
        let plane = try #require(shapes.last?.geometry)
        #expect((plane.mesh.bounds.max - plane.mesh.bounds.min) == SIMD3<Float>(2, 3, 0))
        #expect(abs((plane.materials.first?.descriptor.roughness.color?.x ?? 0) - 0.4) < 0.0001)
    }

    @Test func colladaTransformsMeshAndMaterials() throws {
        let source = """
        <?xml version="1.0"?>
        <COLLADA xmlns="http://www.collada.org/2005/11/COLLADASchema" version="1.4.1">
          <asset><unit meter="0.01"/><up_axis>Z_UP</up_axis></asset>
          <library_effects><effect id="effect"><profile_COMMON><technique sid="common"><lambert><diffuse><color>1 0.5 0 1</color></diffuse></lambert></technique></profile_COMMON></effect></library_effects>
          <library_materials><material id="material" name="Orange"><instance_effect url="#effect"/></material></library_materials>
          <library_geometries><geometry id="mesh"><mesh>
            <source id="positions"><float_array id="array" count="12">0 0 0 100 0 0 100 100 0 0 100 0</float_array><technique_common><accessor source="#array" count="4" stride="3"/></technique_common></source>
            <vertices id="vertices"><input semantic="POSITION" source="#positions"/></vertices>
            <polylist count="1" material="surface"><input semantic="VERTEX" source="#vertices" offset="0"/><vcount>4</vcount><p>0 1 2 3</p></polylist>
          </mesh></geometry></library_geometries>
          <library_visual_scenes><visual_scene id="scene"><node name="A &amp; B"><matrix>1 0 0 200 0 1 0 300 0 0 1 400 0 0 0 1</matrix><instance_geometry url="#mesh"><bind_material><technique_common><instance_material symbol="surface" target="#material"/></technique_common></bind_material></instance_geometry></node></visual_scene></library_visual_scenes>
          <scene><instance_visual_scene url="#scene"/></scene>
        </COLLADA>
        """
        let scene = try ColladaDecoder().decodeScene(Array(source.utf8))
        let node = try #require(scene.rootNode.childNode(named: "A & B"))
        #expect((node.worldPosition - SIMD3<Float>(2, 4, -3)).length < 0.001)
        let geometry = try #require(node.children.first?.geometry)
        #expect(geometry.mesh.triangles(in: geometry.mesh.submeshes[0]).count == 2)
        #expect(geometry.materials.first?.descriptor.name == "Orange")
        #expect(geometry.mesh.stream(.normal) != nil)
        #expect(throws: SceneFormatError.self) {
            try ColladaDecoder().decodeScene(Array(source.replacingOccurrences(of: "0 1 2 3</p>", with: "0 1 2 9</p>").utf8))
        }
    }

    @Test func xmlRejectsEntitiesAndUnbalancedTags() throws {
        for source in ["<!DOCTYPE a [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><a>&x;</a>", "<a><b></a>", "<a>&unknown;</a>"] {
            #expect(throws: SceneFormatError.self) { try AssetXML.parse(Array(source.utf8)) }
        }
    }
}
