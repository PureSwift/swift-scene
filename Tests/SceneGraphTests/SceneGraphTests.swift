import Testing
import SceneCore
@testable import SceneGraph

private func isClose(_ a: SIMD3<Float>, _ b: SIMD3<Float>, tolerance: Float = 1e-4) -> Bool {
    abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance && abs(a.z - b.z) <= tolerance
}

@Suite struct NodeTests {

    @Test func worldTransformComposesParents() {
        let parent = Node().positioned(at: SIMD3(10, 0, 0))
        parent.eulerAngles = SIMD3(0, .pi / 2, 0)
        let child = Node().positioned(at: SIMD3(1, 0, 0))
        parent.addChild(child)
        #expect(isClose(child.worldPosition, SIMD3(10, 0, -1)))
        #expect(isClose(child.convertPosition(.zero, to: parent), SIMD3(1, 0, 0)))
        #expect(isClose(parent.convertPosition(SIMD3(10, 0, -1), from: nil), SIMD3(1, 0, 0)))
    }

    @Test func addingMovesIntoParentsStore() {
        let root = Node(), branch = Node(), leaf = Node()
        branch.addChild(leaf)
        let oldStore = branch.store
        root.addChild(branch)
        #expect(branch.store === root.store)
        #expect(leaf.store === root.store)
        #expect(oldStore.entityCount == 0)
        #expect(root.store[Parent.self, leaf.entity]?.entity == branch.entity)
        #expect(root.store[Parent.self, branch.entity]?.entity == root.entity)
    }

    @Test func reparentingAndCycles() {
        let a = Node(name: "a"), b = Node(name: "b"), c = Node(name: "c")
        a.addChild(b)
        b.addChild(c)
        c.addChild(a)
        #expect(a.parent == nil)
        a.addChild(c)
        #expect(c.parent === a)
        #expect(b.children.isEmpty)
        #expect(a.childNode(named: "c") === c)
        c.removeFromParent()
        #expect(a.children.map(\.name) == ["b"])
        #expect(a.store[Parent.self, c.entity] == nil)
    }

    @Test func releasedNodesFreeTheirEntities() {
        let root = Node()
        do {
            let child = Node()
            root.addChild(child)
            #expect(root.store.entityCount == 2)
            child.removeFromParent()
        }
        #expect(root.store.entityCount == 1)
    }

    @Test func eulerAnglesReadBackAsSet() {
        let node = Node()
        node.eulerAngles = SIMD3(0, .pi / 2, 0)
        #expect(node.eulerAngles == SIMD3(0, .pi / 2, 0))
        node.orientation = Quaternion(angle: .pi / 2, axis: SIMD3(0, 1, 0))
        #expect(abs(node.eulerAngles.y + .pi / 2) < 1e-4)
    }

    @Test func settingTransformDecomposes() {
        let node = Node()
        node.transform = Matrix4x4(translation: SIMD3(1, 2, 3)) * Matrix4x4(scale: SIMD3(2, 2, 2))
        #expect(node.position == SIMD3(1, 2, 3))
        #expect(isClose(node.scale, SIMD3(2, 2, 2)))
    }

    @Test func builderMakesTree() {
        let showsMoon = true
        let scene = Scene {
            Node(name: "earth", geometry: .sphere()) {
                if showsMoon {
                    Node(name: "moon", geometry: .sphere(radius: 0.1)).positioned(at: SIMD3(2, 0, 0))
                }
            }
            for i in 0..<3 {
                Node(name: "star \(i)")
            }
        }
        #expect(scene.rootNode.children.count == 4)
        #expect(scene.rootNode.childNode(named: "moon")?.parent?.name == "earth")
        #expect(scene.rootNode.childNode(named: "moon")?.store === scene.store)
    }

    @Test func cloneSharesGeometry() {
        let original = Node(name: "n", geometry: .box()) {
            Node(name: "child")
        }
        original.position = SIMD3(1, 2, 3)
        let copy = original.clone()
        #expect(copy !== original)
        #expect(copy.geometry === original.geometry)
        #expect(copy.position == SIMD3(1, 2, 3))
        #expect(copy.childNode(named: "child") !== original.childNode(named: "child"))
    }
}

@Suite struct PrimitiveTests {

    @Test(arguments: [
        (Primitive.box(width: 1, height: 2, length: 3), 6),
        (.sphere(radius: 1, segmentCount: 12), 1),
        (.plane(width: 1, height: 1), 1),
        (.floor(), 1),
        (.cylinder(radius: 1, height: 1, radialSegmentCount: 8), 3),
        (.cone(topRadius: 0, bottomRadius: 1, height: 1, radialSegmentCount: 8), 3),
        (.tube(innerRadius: 0.5, outerRadius: 1, height: 1, radialSegmentCount: 8), 4),
        (.torus(ringRadius: 1, pipeRadius: 0.25, ringSegmentCount: 8, pipeSegmentCount: 6), 1),
        (.pyramid(width: 1, height: 1, length: 1), 5),
        (.capsule(capRadius: 0.5, height: 2, radialSegmentCount: 8, capSegmentCount: 4), 1),
    ])
    func submeshesAndStreams(_ primitive: Primitive, submeshCount: Int) {
        let mesh = primitive.makeMesh()
        #expect(mesh.submeshes.count == submeshCount)
        #expect(mesh.vertexCount % 3 == 0)
        #expect(mesh.stream(.normal)?.vertexCount == mesh.vertexCount)
        #expect(mesh.stream(.textureCoordinate(0))?.vertexCount == mesh.vertexCount)
        #expect(mesh.submeshes.last?.range.upperBound == mesh.vertexCount)
    }

    @Test(arguments: [
        Primitive.box(width: 1, height: 2, length: 3),
        .sphere(radius: 1, segmentCount: 16),
        .cylinder(radius: 1, height: 2, radialSegmentCount: 16),
        .pyramid(width: 1, height: 1, length: 1),
        .capsule(capRadius: 0.5, height: 2, radialSegmentCount: 16, capSegmentCount: 6),
    ])
    func trianglesFaceOutward(_ primitive: Primitive) {
        let mesh = primitive.makeMesh()
        let positions = mesh.positions
        let center = mesh.bounds.center
        for submesh in mesh.submeshes {
            for t in mesh.triangles(in: submesh) {
                let a = positions[t.x], b = positions[t.y], c = positions[t.z]
                let normal = (b - a).cross(c - a)
                // Degenerate triangles at a sphere's poles have no facing.
                guard normal.length > 1e-6 else { continue }
                #expect(normal.dot((a + b + c) / 3 - center) > 0)
            }
        }
    }

    @Test func boxBounds() {
        #expect(MeshBuffer.box(width: 1, height: 2, length: 3).bounds == BoundingBox(min: SIMD3(-0.5, -1, -1.5), max: SIMD3(0.5, 1, 1.5)))
        #expect(MeshBuffer.capsule(capRadius: 0.5, height: 3).bounds.extents.y == 3)
    }

    @Test func materialsRepeat() {
        let red = Material(.unlit(color: SIMD4(1, 0, 0, 1))), blue = Material(.unlit(color: SIMD4(0, 0, 1, 1)))
        let box = Geometry.box()
        box.materials = [red, blue]
        #expect(box.material(forSubmesh: 0) === red)
        #expect(box.material(forSubmesh: 3) === blue)
        #expect(box.material(forSubmesh: 4) === red)
    }
}

@Suite struct ActionTests {

    @Test func moveFinishesAtTarget() {
        let scene = Scene()
        let node = Node()
        scene.rootNode.addChild(node)
        var finished = false
        node.runAction(.move(to: SIMD3(10, 0, 0), duration: .seconds(1))) { finished = true }
        scene.update(by: .milliseconds(500))
        #expect(isClose(node.position, SIMD3(5, 0, 0)))
        #expect(!finished)
        scene.update(by: .milliseconds(600))
        #expect(isClose(node.position, SIMD3(10, 0, 0)))
        #expect(finished)
        #expect(!node.hasActions)
    }

    @Test func sequenceCarriesLeftoverTime() {
        let node = Node()
        node.runAction(.sequence([
            .move(by: SIMD3(1, 0, 0), duration: .milliseconds(100)),
            .move(by: SIMD3(0, 1, 0), duration: .milliseconds(100)),
        ]))
        node.advanceActions(by: .milliseconds(150))
        #expect(isClose(node.position, SIMD3(1, 0.5, 0)))
    }

    @Test func groupAndRepeat() {
        let node = Node()
        node.runAction(.repeat(.group([
            .move(by: SIMD3(1, 0, 0), duration: .milliseconds(100)),
            .fadeOpacity(by: -0.25, duration: .milliseconds(50)),
        ]), count: 2))
        node.advanceActions(by: .milliseconds(250))
        #expect(isClose(node.position, SIMD3(2, 0, 0)))
        #expect(abs(node.opacity - 0.5) < 1e-4)
        #expect(!node.hasActions)
    }

    @Test func reversedUndoes() {
        let node = Node()
        let turn = Action.rotate(by: 1, around: SIMD3(0, 1, 0), duration: .milliseconds(100))
        node.runAction(.sequence([turn, turn.reversed()]))
        node.advanceActions(by: .milliseconds(200))
        #expect(abs(node.orientation.angle) < 1e-3 || abs(node.orientation.angle - 2 * .pi) < 1e-3)
    }

    @Test func keyedActionsReplace() {
        let node = Node()
        node.runAction(.wait(duration: .seconds(1)), forKey: "k")
        node.runAction(.wait(duration: .seconds(2)), forKey: "k")
        #expect(node.actionKeys == ["k"])
        #expect(node.action(forKey: "k")?.duration == .seconds(2))
        node.removeAction(forKey: "k")
        #expect(!node.hasActions)
    }

    @Test func pausedNodesWait() {
        let parent = Node(), child = Node()
        parent.addChild(child)
        child.runAction(.move(by: SIMD3(1, 0, 0), duration: .milliseconds(100)))
        parent.isPaused = true
        parent.advanceActions(by: .milliseconds(100))
        #expect(child.position == .zero)
    }

    @Test func transactionCompletesAfterDuration() {
        let scene = Scene()
        var completed = false
        scene.perform(Transaction(animationDuration: .milliseconds(200), completion: { completed = true })) {
            scene.rootNode.position = SIMD3(1, 1, 1)
        }
        #expect(scene.rootNode.position == SIMD3(1, 1, 1))
        scene.update(by: .milliseconds(100))
        #expect(!completed)
        scene.update(by: .milliseconds(100))
        #expect(completed)
    }
}

@Suite struct RendererTests {

    private func makeScene() -> Scene {
        Scene {
            Node(name: "camera").camera(Camera()).positioned(at: SIMD3(0, 0, 10))
            Node(name: "box", geometry: .box())
            Node(name: "hidden", geometry: .sphere()).hidden()
            Node(name: "behind", geometry: .sphere()).positioned(at: SIMD3(0, 0, 50))
            Node(name: "glass", geometry: .plane()).opacity(0.5).positioned(at: SIMD3(0, 0, 2))
        }
    }

    @Test func drawsVisibleSubmeshes() throws {
        let renderer = SceneRenderer(backend: HeadlessRenderBackend(), scene: makeScene())
        try renderer.render(target: RenderTargetDescriptor(width: 640, height: 480))
        let frame = try #require(renderer.backend.lastFrame)
        // The box's six faces, then the translucent plane last; the hidden and culled spheres not at all.
        #expect(frame.drawCalls.count == 7)
        #expect(frame.drawCalls.last?.opacity == 0.5)
        #expect(frame.drawCalls.allSatisfy { $0.meshKey != nil })
    }

    @Test func noCameraFramesScene() throws {
        let scene = Scene { Node(geometry: .box(width: 4, height: 4, length: 4)) }
        let renderer = SceneRenderer(backend: HeadlessRenderBackend(), scene: scene)
        renderer.autoenablesDefaultLighting = true
        try renderer.render(target: RenderTargetDescriptor(width: 100, height: 100))
        let frame = try #require(renderer.backend.lastFrame)
        #expect(frame.drawCalls.count == 6)
        let lights = frame.commands.compactMap { if case .setLights(let lights) = $0 { lights } else { nil } }
        #expect(lights.first?.count == 2)
    }

    @Test func hitTestFindsNearest() {
        let scene = makeScene()
        let hits = scene.hitTest(Ray(origin: SIMD3(0, 0, 10), direction: SIMD3(0, 0, -1)))
        #expect(hits.first?.node.name == "glass")
        #expect(hits.contains { $0.node.name == "box" && abs($0.distance - 9.5) < 1e-4 })
        #expect(!hits.contains { $0.node.name == "hidden" })
    }
}
