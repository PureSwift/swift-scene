import Foundation
import Testing
import SceneCore
import SceneGraph
@testable import SceneFormats

@Suite struct SCNReferenceTests {
    private func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: "scn", subdirectory: "Fixtures/References"))
    }

    @Test func legacyDataAndAxisAngleRotation() throws {
        let scene = try SceneAssetFile(url: fixture("assets/leaf")).load()
        let triangle = try #require(scene.rootNode.childNode(named: "triangle"))
        let mesh = try #require(triangle.geometry?.mesh)
        #expect(mesh.vertexCount == 3)
        #expect(mesh.indices == IndexBuffer([0, 1, 2]))
        #expect((triangle.orientation.act(SIMD3<Float>(1, 0, 0)) - SIMD3(0, 1, 0)).length < 0.00001)
    }

    @Test func nestedReferencesAreRelativeCachedAndIndependent() throws {
        let root = try fixture("root")
        var paths: [String] = []
        let decoder = SCNArchiveDecoder(resourceLoader: { path in
            paths.append(path)
            return [UInt8](try Data(contentsOf: root.deletingLastPathComponent().appendingPathComponent(path)))
        })
        let scene = try decoder.decodeScene([UInt8](Data(contentsOf: root)))
        let triangles = scene.rootNode.childNodes { $0.name == "triangle" }
        try #require(triangles.count == 2)
        #expect(triangles[0].worldPosition == SIMD3(6, 12, 3))
        #expect(triangles[1].worldPosition == SIMD3(-4, 12, 3))
        #expect(paths == ["models/branch.scn", "assets/leaf.scn", "assets/textures/red.jpg"])
        #expect(triangles[0].entity != triangles[1].entity)
        triangles[0].position = SIMD3(9, 8, 7)
        #expect(triangles[1].position == .zero)
        let asset = SceneAssetFile(url: root)
        _ = try asset.load()
        #expect(asset.dependencies.count == 4)
    }

    private func replacingReferences(_ bytes: [UInt8], with path: String) throws -> [UInt8] {
        var plist = try #require(PropertyListSerialization.propertyList(from: Data(bytes), format: nil) as? [String: Any])
        // Preserve non-dictionary objects (including the null sentinel) in the original array.
        var raw = try #require(plist["$objects"] as? [Any])
        for index in raw.indices {
            guard var value = raw[index] as? [String: Any], value["NS.relative"] != nil else { continue }
            value["NS.relative"] = path
            raw[index] = value
        }
        plist["$objects"] = raw
        return [UInt8](try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0))
    }

    @Test func rejectsCyclesMissingAndUnsupportedReferences() throws {
        let bytes = [UInt8](try Data(contentsOf: fixture("root")))
        for path in ["./scene.scn", "models/../scene.scn", "https://example.com/model.scn", "/model.scn", "model.dae"] {
            let changed = try replacingReferences(bytes, with: path)
            var reads = 0
            let decoder = SCNArchiveDecoder(resourceLoader: { _ in reads += 1; return changed })
            #expect(throws: SceneFormatError.self) { try decoder.decodeScene(changed) }
            #expect(reads == 0)
        }
        #expect(throws: SceneFormatError.self) { try SCNArchiveDecoder().decodeScene(bytes) }
        let cycle = try replacingReferences(bytes, with: "loop.scn")
        #expect(throws: SceneFormatError.self) {
            try SCNArchiveDecoder(resourceLoader: { _ in cycle }).decodeScene(bytes)
        }
    }
    @Test func rejectsMalformedLegacyData() throws {
        let bytes = try Data(contentsOf: fixture("assets/leaf"))
        var plist = try #require(PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any])
        var objects = try #require(plist["$objects"] as? [Any])
        for index in objects.indices {
            guard var value = objects[index] as? [String: Any], value["NS.data"] != nil else { continue }
            value["NS.data"] = "not binary data"
            objects[index] = value
        }
        plist["$objects"] = objects
        let invalid = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        #expect(throws: SceneFormatError.self) {
            try SCNArchiveDecoder(resourceLoader: { _ in
                [UInt8](try Data(contentsOf: fixture("assets/leaf").deletingLastPathComponent().appendingPathComponent("textures/red.jpg")))
            }).decodeScene([UInt8](invalid))
        }
    }

    @Test func boundsReferenceDepthAndReportsMissingFiles() throws {
        let bytes = [UInt8](try Data(contentsOf: fixture("root")))
        #expect(throws: SceneFormatError.self) {
            try SCNArchiveDecoder(resourceLoader: { _ in throw SceneFormatError.unsupported("Missing file") }).decodeScene(bytes)
        }
        var reads = 0
        let decoder = SCNArchiveDecoder(resourceLoader: { _ in
            reads += 1
            return try replacingReferences(bytes, with: "level\(reads).scn")
        })
        #expect(throws: SceneFormatError.self) { try decoder.decodeScene(bytes) }
        #expect(reads == 16)
    }

    @Test func resolvesParentDirectoriesAndEncodedFilenames() throws {
        let root = [UInt8](try Data(contentsOf: fixture("root")))
        let leafURL = try fixture("assets/leaf")
        let leaf = [UInt8](try Data(contentsOf: leafURL))
        let jpeg = [UInt8](try Data(contentsOf: leafURL.deletingLastPathComponent().appendingPathComponent("textures/red.jpg")))
        let archive = try replacingReferences(root, with: "../leaf%20model.scn")
        var paths: [String] = []
        _ = try SCNArchiveDecoder(resourceLoader: { path in
            paths.append(path)
            return path.hasSuffix(".jpg") ? jpeg : leaf
        }).decodeScene(archive)
        #expect(paths == ["../leaf%20model.scn", "../textures/red.jpg"])
    }

}
