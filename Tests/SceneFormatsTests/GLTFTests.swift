import Foundation
import Testing
import SceneCore
import SceneGraph
@testable import SceneFormats

@Suite struct GLTFTests {
    private func json(_ object: [String: Any]) throws -> [UInt8] {
        Array(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }

    private func words(_ values: [UInt32]) -> [UInt8] {
        values.flatMap { value in (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
    }

    private func floats(_ values: [Float]) -> [UInt8] { words(values.map(\.bitPattern)) }

    private func document(_ bytes: [UInt8], accessors: [[String: Any]], views: [[String: Any]]) -> [String: Any] {
        ["asset": ["version": "2.0"],
         "buffers": [["byteLength": bytes.count, "uri": "data:application/octet-stream;base64," + Data(bytes).base64EncodedString()]],
         "bufferViews": views, "accessors": accessors]
    }

    @Test func loadsGLBAndExternalBuffers() throws {
        let bytes = floats([0, 0, 0, 1, 0, 0, 0, 1, 0])
        var source = document(bytes, accessors: [["bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"]],
                              views: [["buffer": 0, "byteLength": bytes.count]])
        source["meshes"] = [["primitives": [["attributes": ["POSITION": 0]]]]]
        source["nodes"] = [["mesh": 0, "name": "triangle", "translation": [2, 3, 4]]]
        source["scenes"] = [["nodes": [0]]]
        source["buffers"] = [["byteLength": bytes.count, "uri": "mesh.bin"]]
        var calls = 0
        let external = try GLTFDecoder(resourceLoader: { uri in
            #expect(uri == "mesh.bin")
            calls += 1
            return bytes
        }).decodeScene(json(source))
        #expect(calls == 1)
        #expect(external.rootNode.children[0].position == SIMD3(2, 3, 4))
        source["buffers"] = [["byteLength": bytes.count]]
        var jsonBytes = try json(source)
        while jsonBytes.count % 4 != 0 { jsonBytes.append(32) }
        let length = 12 + 8 + jsonBytes.count + 8 + bytes.count
        let glb = words([0x46546c67, 2, UInt32(length), UInt32(jsonBytes.count), 0x4e4f534a])
            + jsonBytes + words([UInt32(bytes.count), 0x004e4942]) + bytes
        let scene = try GLTFDecoder().decodeScene(glb)
        let geometry = try #require(scene.rootNode.children[0].children.first?.geometry)
        #expect(geometry.mesh.positions == [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)])
        #expect(geometry.firstMaterial?.lightingModel == .physicallyBased)
        for end in 0..<glb.count {
            #expect(throws: SceneFormatError.self) { try GLTFDecoder().decodeScene(Array(glb.prefix(end))) }
        }
    }

    @Test func decodesInterleavedNormalizedAndSparseAccessors() throws {
        let bytes: [UInt8] = [0, 127, 255, 9, 64, 128, 192, 9, 1, 0, 0, 0] + floats([2, 3, 4])
        let source = document(bytes, accessors: [
            ["bufferView": 0, "componentType": 5121, "normalized": true, "count": 2, "type": "VEC3"],
            ["componentType": 5126, "count": 3, "type": "VEC3",
             "sparse": ["count": 1, "indices": ["bufferView": 1, "componentType": 5121], "values": ["bufferView": 2]]]
        ], views: [
            ["buffer": 0, "byteLength": 8, "byteStride": 4],
            ["buffer": 0, "byteOffset": 8, "byteLength": 1],
            ["buffer": 0, "byteOffset": 12, "byteLength": 12]
        ])
        let storage = try GLTFStorage(json(source), resourceLoader: nil)
        #expect(try storage.accessor(0).values == [0, 127.0 / 255, 1, 64.0 / 255, 128.0 / 255, 192.0 / 255])
        #expect(try storage.accessor(1).values == [0, 0, 0, 2, 3, 4, 0, 0, 0])
    }

    @Test func respectsMatrixColumnPadding() throws {
        let source = document([1, 2, 3, 0, 4, 5, 6, 0, 7, 8, 9, 0],
                              accessors: [["bufferView": 0, "componentType": 5121, "count": 1, "type": "MAT3"]],
                              views: [["buffer": 0, "byteLength": 12]])
        #expect(try GLTFStorage(json(source), resourceLoader: nil).accessor(0).values == [1, 2, 3, 4, 5, 6, 7, 8, 9])
    }

    @Test func rejectsMalformedReferencesAndCycles() throws {
        for source: [String: Any] in [
            ["asset": ["version": "1.0"]],
            ["asset": ["version": "2.0"], "nodes": [["children": [1]], ["children": [0]]]],
            ["asset": ["version": "2.0"], "nodes": [["mesh": 2]]],
            ["asset": ["version": "2.0"], "extensionsRequired": ["UNSUPPORTED"]],
            ["asset": ["version": "2.0"], "nodes": [["children": [1, 1]], [:]]]
        ] {
            let bytes = try json(source)
            #expect(throws: SceneFormatError.self) { try GLTFDecoder().decodeScene(bytes) }
        }
        var source = document([0, 0, 0, 0], accessors: [
            ["bufferView": 0, "byteOffset": Int.max, "componentType": 5126, "count": 3, "type": "VEC3"]
        ], views: [["buffer": 0, "byteLength": 4]])
        let storage = try GLTFStorage(json(source), resourceLoader: nil)
        #expect(throws: SceneFormatError.self) { try storage.accessor(0) }
        source["bufferViews"] = [["buffer": 0, "byteOffset": Int.max, "byteLength": 4]]
        let invalid = try GLTFStorage(json(source), resourceLoader: nil)
        #expect(throws: SceneFormatError.self) { try invalid.accessor(0) }
    }

    @Test func animatesSkinnedMesh() throws {
        let positions = floats([0, 0, 0, 1, 0, 0, 0, 1, 0])
        let joints = [UInt8](repeating: 0, count: 12)
        let weights = floats([1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0])
        let times = floats([0, 1])
        let translations = floats([0, 0, 0, 2, 0, 0])
        let chunks = [positions, joints, weights, times, translations]
        var offset = 0
        var views: [[String: Any]] = []
        for chunk in chunks {
            views.append(["buffer": 0, "byteOffset": offset, "byteLength": chunk.count])
            offset += chunk.count
        }
        var source = document(chunks.flatMap { $0 }, accessors: [
            ["bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"],
            ["bufferView": 1, "componentType": 5121, "count": 3, "type": "VEC4"],
            ["bufferView": 2, "componentType": 5126, "count": 3, "type": "VEC4"],
            ["bufferView": 3, "componentType": 5126, "count": 2, "type": "SCALAR"],
            ["bufferView": 4, "componentType": 5126, "count": 2, "type": "VEC3"]
        ], views: views)
        source["meshes"] = [["primitives": [["attributes": ["POSITION": 0, "JOINTS_0": 1, "WEIGHTS_0": 2]]]]]
        source["nodes"] = [["mesh": 0, "skin": 0], ["name": "joint"]]
        source["skins"] = [["joints": [1]]]
        source["animations"] = [["samplers": [["input": 3, "output": 4]],
                                  "channels": [["sampler": 0, "target": ["node": 1, "path": "translation"]]]]]
        let scene = try GLTFDecoder().decodeScene(json(source))
        let geometry = try #require(scene.rootNode.children[0].children.first?.geometry)
        let initial = geometry.mesh.positions
        scene.update(by: .milliseconds(500))
        #expect(geometry.mesh.positions == initial.map { $0 + SIMD3(1, 0, 0) })
        scene.isPaused = true
        scene.update(by: .milliseconds(500))
        #expect(geometry.mesh.positions == initial.map { $0 + SIMD3(1, 0, 0) })
    }
    @Test func cubicMorphAnimationUsesTangentsAndBaseMesh() throws {
        let chunks = [floats([0,0,0, 1,0,0, 0,1,0]), floats([0,0,2, 0,0,2, 0,0,2]),
                      floats([0,2]), floats([0,0,1, 0,1,0])]
        var offset = 0
        let views: [[String: Any]] = chunks.map { chunk in
            defer { offset += chunk.count }
            return ["buffer": 0, "byteOffset": offset, "byteLength": chunk.count]
        }
        var source = document(chunks.flatMap { $0 }, accessors: [
            ["bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"],
            ["bufferView": 1, "componentType": 5126, "count": 3, "type": "VEC3"],
            ["bufferView": 2, "componentType": 5126, "count": 2, "type": "SCALAR"],
            ["bufferView": 3, "componentType": 5126, "count": 6, "type": "SCALAR"]
        ], views: views)
        source["meshes"] = [["primitives": [["attributes": ["POSITION": 0], "targets": [["POSITION": 1]]]], "weights": [0.25]]]
        source["nodes"] = [["mesh": 0]]
        source["animations"] = [["samplers": [["input": 2, "output": 3, "interpolation": "CUBICSPLINE"]],
            "channels": [["sampler": 0, "target": ["node": 0, "path": "weights"]]]]]
        let scene = try GLTFDecoder().decodeScene(json(source))
        let geometry = try #require(scene.rootNode.children[0].children.first?.geometry)
        scene.update(by: .seconds(1))
        // Hermite h10(0.5) * duration * outgoing tangent + h01(0.5) * value = 0.75.
        #expect(abs(geometry.mesh.positions[0].z - 1.5) < 0.0001)
        scene.update(by: .zero)
        #expect(abs(geometry.mesh.positions[0].z - 1.5) < 0.0001)
        let runtime = try #require(scene.systems.first as? GLTFSceneRuntime)
        runtime.loops = false
        scene.update(by: .seconds(2))
        #expect(abs(geometry.mesh.positions[0].z - 2) < 0.0001)
    }

    @Test func cameraPreservesOrthographicMagnitudes() throws {
        let scene = try GLTFDecoder().decodeScene(json([
            "asset": ["version": "2.0"], "nodes": [["camera": 0]],
            "cameras": [["type": "orthographic", "orthographic": ["xmag": 4, "ymag": 2, "znear": 0, "zfar": 100]]]
        ]))
        let camera = try #require(scene.rootNode.children[0].camera)
        let matrix = camera.descriptor.projectionMatrix(aspectRatio: 1)
        #expect(abs(matrix.transformPoint(SIMD3(4, 2, -50)).x - 1) < 0.0001)
        #expect(abs(matrix.transformPoint(SIMD3(4, 2, -50)).y - 1) < 0.0001)
    }

}
