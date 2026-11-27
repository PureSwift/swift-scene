import Foundation
import Testing
import SceneCore
import SceneGraph
import SceneFormats
@testable import scene_viewer

@Suite struct ViewerTests {
    @Test func inspectorSelectionAndOverlay() {
        let scene = Scene { Node(name: "box", geometry: .box()) }
        var inspector = ViewerInspector(isVisible: true)
        inspector.rebuild(scene)
        inspector.move(1)
        #expect(inspector.selectedNode?.name == "box")
        inspector.selectedNode?.isHidden.toggle()
        #expect(scene.rootNode.children[0].isHidden)
        inspector.move(100)
        #expect(inspector.selection == 1)
        var commands = RecordedCommandBuffer(target: RenderTargetDescriptor(width: 1280, height: 720))
        inspector.encode(into: &commands, fly: false, status: "READY")
        #expect(commands.drawCalls.count == 1)
        #expect(commands.drawCalls[0].material.readsFromDepthBuffer == false)
        #expect(commands.drawCalls[0].mesh.vertexCount > 100)
    }

    @Test func orbitPreservesDistanceAndPointsAtTarget() {
        var orbit = OrbitCamera(target: SIMD3(1, 2, 3), distance: 10)
        let node = Node()
        orbit.drag(dx: 40, dy: -20)
        orbit.apply(to: node)
        #expect(abs((node.position - orbit.target).length - 10) < 0.001)
        #expect(((-node.worldTransform.columns.2.xyz).normalized - (orbit.target - node.position).normalized).length < 0.001)
    }

    @Test func flyLooksInPlaceAndMovesAlongView() {
        var orbit = OrbitCamera(target: .zero, distance: 5)
        let node = Node()
        orbit.apply(to: node)
        let eye = node.position
        orbit.look(dx: 35, dy: -12)
        orbit.apply(to: node)
        #expect((node.position - eye).length < 0.0001)
        let direction = -orbit.offset
        orbit.move(forward: 1, right: 0, up: 0, seconds: 0.5)
        orbit.apply(to: node)
        #expect((node.position - eye - direction * 2.5).length < 0.0001)
    }

    @Test func watcherTracksBufferEditsAndDeletion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("scene.gltf")
        let buffer = directory.appendingPathComponent("mesh.bin")
        try Data([0, 0, 0, 0]).write(to: buffer)
        try Data(#"{"asset":{"version":"2.0"},"buffers":[{"uri":"mesh.bin","byteLength":4}]}"#.utf8).write(to: source)
        let asset = SceneAssetFile(url: source)
        _ = try asset.load()
        #expect(asset.dependencies.contains(buffer))
        var watcher = AssetWatcher()
        watcher.synchronize(asset)
        let changed1 = watcher.changed(asset, delta: 1)
        #expect(!changed1)
        try Data([0, 0, 0, 0, 0]).write(to: buffer)
        let changed2 = watcher.changed(asset, delta: 1)
        #expect(changed2)
        let changed3 = watcher.changed(asset, delta: 1)
        #expect(!changed3)
        try FileManager.default.removeItem(at: buffer)
        let changed4 = watcher.changed(asset, delta: 1)
        #expect(changed4)
        #expect(throws: SceneFormatError.self) { try asset.load() }
        try Data([0, 0, 0, 0]).write(to: buffer)
        let changed5 = watcher.changed(asset, delta: 1)
        #expect(changed5)
        _ = try asset.load()
    }
}
