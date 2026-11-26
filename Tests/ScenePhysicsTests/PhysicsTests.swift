#if canImport(CBox3D)
import Testing
import SceneCore
@testable import ScenePhysics

@Suite struct PhysicsWorldTests {

    /// A world with a static ground box whose top is at y = 0.
    private func makeWorld() -> PhysicsWorld {
        let world = PhysicsWorld()
        let ground = world.addBody(PhysicsBodyDescriptor(type: .static, position: SIMD3(0, -1, 0)))
        ground.addShape(.box(halfExtents: SIMD3(10, 1, 10)))
        return world
    }

    private func settle(_ world: PhysicsWorld, seconds: Float = 3) {
        for _ in 0 ..< Int(seconds * 60) { world.step(seconds: 1.0 / 60) }
    }

    @Test func bodyFallsUnderGravity() {
        let world = PhysicsWorld()
        let ball = world.addBody(PhysicsBodyDescriptor(position: SIMD3(0, 10, 0)))
        ball.addShape(.sphere(radius: 0.5))
        for _ in 0..<60 { world.step(seconds: 1.0 / 60) }
        // A second's free fall at 9.8 is 4.9 down; the solver's semi-implicit steps fall a little further.
        #expect(ball.position.y > 4.8 && ball.position.y < 5.15)
        #expect(abs(ball.linearVelocity.y + 9.8) < 0.01)
    }

    @Test func sphereComesToRestOnTheGround() {
        let world = makeWorld()
        let ball = world.addBody(PhysicsBodyDescriptor(position: SIMD3(0, 3, 0)))
        ball.addShape(.sphere(radius: 0.5))
        settle(world)
        #expect(abs(ball.position.y - 0.5) < 0.05)
        #expect(ball.linearVelocity.length < 0.05)
    }

    @Test func massComesFromDensity() {
        let world = PhysicsWorld()
        let box = world.addBody()
        box.addShape(.box(halfExtents: SIMD3(1, 1, 1)), material: PhysicsMaterial(density: 2))
        // Two units a side: eight cubic units at density two.
        #expect(abs(box.mass - 16) < 1e-3)
    }

    @Test func impulseChangesVelocity() {
        let world = PhysicsWorld(gravity: .zero)
        let box = world.addBody()
        box.addShape(.box(halfExtents: SIMD3(repeating: 0.5)))
        box.applyImpulse(SIMD3(3, 0, 0))
        #expect(abs(box.linearVelocity.x - 3) < 1e-4)
    }

    @Test func capsuleAndHullStandOnAMeshFloor() {
        let world = PhysicsWorld()
        let floor = world.addBody(PhysicsBodyDescriptor(type: .static))
        let quad = MeshBuffer(
            vertexCount: 4,
            streams: [VertexStream(semantic: .position, vectors: [SIMD3<Float>(-5, 0, 5), SIMD3(5, 0, 5), SIMD3(5, 0, -5), SIMD3(-5, 0, -5)])],
            indices: IndexBuffer([0, 1, 2, 0, 2, 3]),
            submeshes: [Submesh(range: 0..<6, materialIndex: 0)]
        )
        #expect(floor.addShape(.triangleMesh(quad)) != nil)
        let capsule = world.addBody(PhysicsBodyDescriptor(position: SIMD3(-2, 2, 0)))
        capsule.addShape(.capsule(SIMD3(0, -0.5, 0), SIMD3(0, 0.5, 0), radius: 0.25))
        let hull = world.addBody(PhysicsBodyDescriptor(position: SIMD3(2, 2, 0)))
        hull.addShape(.convexHull([SIMD3(-0.5, -0.5, -0.5), SIMD3(0.5, -0.5, -0.5), SIMD3(0, -0.5, 0.5), SIMD3(0, 0.5, 0)]))
        settle(world)
        #expect(capsule.position.y > 0 && capsule.position.y < 0.8)
        #expect(hull.position.y > -0.1 && hull.position.y < 1)
    }

    @Test func rayFindsTheNearestBody() {
        let world = makeWorld()
        let ball = world.addBody(PhysicsBodyDescriptor(type: .static, position: SIMD3(0, 2, 0)))
        ball.addShape(.sphere(radius: 0.5))
        let hit = world.castRay(from: SIMD3(0, 10, 0), along: SIMD3(0, -20, 0))
        #expect(hit?.body === ball)
        #expect(abs((hit?.point.y ?? 0) - 2.5) < 1e-3)
    }

    @Test func contactsReportTheBodies() {
        let world = makeWorld()
        let ball = world.addBody(PhysicsBodyDescriptor(position: SIMD3(0, 0.6, 0)))
        ball.addShape(.sphere(radius: 0.5))
        var touched = false
        for _ in 0..<60 {
            world.step(seconds: 1.0 / 60)
            if world.contactsBegun.contains(where: { $0.0 === ball || $0.1 === ball }) { touched = true }
        }
        #expect(touched)
    }

    @Test func removedBodiesStopBeingValid() {
        let world = makeWorld()
        let ball = world.addBody()
        ball.addShape(.sphere(radius: 0.5))
        world.remove(ball)
        #expect(!ball.isValid)
        #expect(world.bodies.count == 1)
        ball.applyImpulse(SIMD3(1, 0, 0)) // Does nothing, rather than touching a freed body.
    }

    @Test func worldsOnManyThreads() async {
        // Box3D's world table is global; worlds made, stepped and freed at once mustn't trip over each other.
        await withTaskGroup(of: Float.self) { group in
            for i in 0..<16 {
                group.addTask {
                    let world = PhysicsWorld()
                    let ball = world.addBody(PhysicsBodyDescriptor(position: SIMD3(Float(i), 10, 0)))
                    ball.addShape(.sphere(radius: 0.5))
                    for _ in 0..<30 { world.step(seconds: 1.0 / 60) }
                    return ball.position.y
                }
            }
            for await y in group { #expect(y < 10) }
        }
    }

    @Test func entitiesFollowTheirBodies() {
        let world = makeWorld()
        let store = EntityStore()
        let entity = store.createEntity()
        store[LocalTransform.self, entity] = LocalTransform(transform: Transform(scale: SIMD3(repeating: 2), translation: SIMD3(0, 3, 0)))
        let ball = world.addBody(PhysicsBodyDescriptor(position: SIMD3(0, 3, 0)))
        ball.addShape(.sphere(radius: 0.5))
        store[PhysicsBodyComponent.self, entity] = PhysicsBodyComponent(ball)
        for _ in 0..<180 { world.step(by: .milliseconds(16), synchronizing: store) }
        let local = store[LocalTransform.self, entity]!.transform
        #expect(abs(local.translation.y - 0.5) < 0.05)
        // The entity's own scale is kept.
        #expect(local.scale == SIMD3(repeating: 2))
    }
}
#endif

#if canImport(CBox3D)
import SceneGraph

@Suite struct PhysicsJointTests {

    @Test func hingeSwingsAndHoldsItsAnchor() {
        let world = PhysicsWorld()
        let post = world.addBody(PhysicsBodyDescriptor(type: .static))
        // A bar hanging from the origin, its top at the hinge, starting level.
        let bar = world.addBody(PhysicsBodyDescriptor(position: SIMD3(1, 0, 0)))
        bar.addShape(.box(halfExtents: SIMD3(1, 0.1, 0.1)))
        let hinge = world.addHingeJoint(post, anchor: .zero, axis: SIMD3(0, 0, 1), bar, anchor: SIMD3(-1, 0, 0), axis: SIMD3(0, 0, 1))
        #expect(hinge != nil)
        for _ in 0..<120 { world.step(seconds: 1.0 / 60) }
        // It has swung down about the z axis, and its end is still at the hinge.
        let end = bar.transform.matrix.transformPoint(SIMD3(-1, 0, 0))
        #expect(end.length < 0.02)
        #expect(bar.position.y < -0.5)
        #expect(abs(bar.position.z) < 0.01)
        #expect(abs(hinge!.angle) > 0.5)
    }

    @Test func hingeLimitsStopTheSwing() {
        let world = PhysicsWorld()
        let post = world.addBody(PhysicsBodyDescriptor(type: .static))
        let bar = world.addBody(PhysicsBodyDescriptor(position: SIMD3(1, 0, 0)))
        bar.addShape(.box(halfExtents: SIMD3(1, 0.1, 0.1)))
        let hinge = world.addHingeJoint(post, anchor: .zero, axis: SIMD3(0, 0, 1), bar, anchor: SIMD3(-1, 0, 0), axis: SIMD3(0, 0, 1),
                                        limits: -0.3 ... 0.3)
        for _ in 0..<120 { world.step(seconds: 1.0 / 60) }
        #expect(abs(hinge!.angle) < 0.35)
    }

    @Test func motorTurnsAWheel() {
        let world = PhysicsWorld(gravity: .zero)
        let axle = world.addBody(PhysicsBodyDescriptor(type: .static))
        let wheel = world.addBody()
        wheel.addShape(.sphere(radius: 0.5))
        world.addHingeJoint(axle, anchor: .zero, axis: SIMD3(0, 1, 0), wheel, anchor: .zero, axis: SIMD3(0, 1, 0),
                            motor: JointMotor(speed: 2, maximumForce: 1000))
        for _ in 0..<60 { world.step(seconds: 1.0 / 60) }
        #expect(abs(wheel.angularVelocity.y - 2) < 0.05)
    }

    @Test func sliderKeepsToItsAxis() {
        let world = PhysicsWorld()
        let rail = world.addBody(PhysicsBodyDescriptor(type: .static))
        let block = world.addBody(PhysicsBodyDescriptor(position: SIMD3(0, 2, 0)))
        block.addShape(.box(halfExtents: SIMD3(repeating: 0.25)))
        // A vertical slider: the block falls along y only, and stops at its limit.
        let slider = world.addSliderJoint(rail, anchor: .zero, axis: SIMD3(0, 1, 0), block, anchor: SIMD3(0, -2, 0), axis: SIMD3(0, 1, 0),
                                          limits: -1 ... 1)
        block.applyImpulse(SIMD3(5, 0, 5))
        for _ in 0..<120 { world.step(seconds: 1.0 / 60) }
        #expect(abs(block.position.x) < 0.01 && abs(block.position.z) < 0.01)
        #expect(abs(slider!.translation + 1) < 0.02)
    }

    @Test func distanceAndBallSocketHoldTheirAnchors() {
        let world = PhysicsWorld()
        let ceiling = world.addBody(PhysicsBodyDescriptor(type: .static, position: SIMD3(0, 5, 0)))
        let bob = world.addBody(PhysicsBodyDescriptor(position: SIMD3(2, 5, 0)))
        bob.addShape(.sphere(radius: 0.2))
        let rope = world.addDistanceJoint(ceiling, anchor: .zero, bob, anchor: .zero)
        #expect(abs((rope?.length ?? 0) - 2) < 1e-5)
        let link = world.addBody(PhysicsBodyDescriptor(position: SIMD3(-1, 5, 0)))
        link.addShape(.sphere(radius: 0.2))
        world.addBallSocketJoint(ceiling, anchor: SIMD3(-1, 0, 0), link, anchor: .zero)
        for _ in 0..<120 { world.step(seconds: 1.0 / 60) }
        #expect(abs((bob.position - SIMD3(0, 5, 0)).length - 2) < 0.02)
        #expect((link.position - SIMD3(-1, 5, 0)).length < 0.02)
    }

    @Test func weldHoldsBodiesTogether() {
        let world = PhysicsWorld()
        let a = world.addBody(PhysicsBodyDescriptor(position: SIMD3(0, 5, 0)))
        a.addShape(.box(halfExtents: SIMD3(repeating: 0.5)))
        let b = world.addBody(PhysicsBodyDescriptor(position: SIMD3(1, 5, 0)))
        b.addShape(.box(halfExtents: SIMD3(repeating: 0.5)))
        world.addWeldJoint(a, b)
        a.applyAngularImpulse(SIMD3(0, 0, 2))
        for _ in 0..<60 { world.step(seconds: 1.0 / 60) }
        #expect(abs((b.position - a.position).length - 1) < 0.02)
    }

    @Test func removingABodyRemovesItsJoints() {
        let world = PhysicsWorld()
        let a = world.addBody(PhysicsBodyDescriptor(type: .static))
        let b = world.addBody()
        b.addShape(.sphere(radius: 0.5))
        let joint = world.addBallSocketJoint(a, anchor: .zero, b, anchor: .zero)
        world.remove(b)
        #expect(joint?.isValid == false)
        #expect(world.joints.isEmpty)
    }
}

@Suite struct ScenePhysicsTests {

    @Test func nodesFallInTheirScene() {
        let scene = Scene {
            Node(name: "ground", geometry: .box(width: 20, height: 1, length: 20)).positioned(at: SIMD3(0, -0.5, 0))
            Node(name: "ball", geometry: .sphere(radius: 0.5)).positioned(at: SIMD3(0, 4, 0))
        }
        let world = scene.physicsWorld
        let ground = scene.rootNode.childNode(named: "ground")!
        let ball = scene.rootNode.childNode(named: "ball")!
        ground.makePhysicsBody(in: world, type: .static, shape: ground.physicsShape(.boundingBox))
        ball.makePhysicsBody(in: world, shape: .sphere(radius: 0.5))
        #expect(scene.physicsWorld === world)
        for _ in 0..<180 { scene.update(by: .milliseconds(16)) }
        #expect(abs(ball.position.y - 0.5) < 0.05)
    }

    @Test func nestedNodesConvertThroughTheirParents() {
        let scene = Scene()
        let world = scene.physicsWorld
        let ground = world.addBody(PhysicsBodyDescriptor(type: .static))
        ground.addShape(.box(halfExtents: SIMD3(20, 0.5, 20), center: SIMD3(0, -0.5, 0)))
        // A parent moved up and turned a quarter about y; the ball inside it starts 4 up in the world.
        let parent = Node().positioned(at: SIMD3(0, 2, 0))
        parent.eulerAngles = SIMD3(0, .pi / 2, 0)
        let ball = Node(geometry: .sphere(radius: 0.5)).positioned(at: SIMD3(0, 2, 0))
        scene.rootNode.addChild(parent)
        parent.addChild(ball)
        ball.makePhysicsBody(in: world, shape: .sphere(radius: 0.5))
        #expect(abs((ball.physicsBody?.position.y ?? 0) - 4) < 1e-4)
        for _ in 0..<180 { scene.update(by: .milliseconds(16)) }
        // At rest on the ground, 0.5 up in the world: -1.5 in its parent.
        #expect(abs(ball.worldPosition.y - 0.5) < 0.05)
        #expect(abs(ball.position.y + 1.5) < 0.05)
    }

    @Test func shapesFromGeometry() {
        let node = Node(geometry: .box(width: 2, height: 4, length: 6)).scaled(SIMD3(repeating: 2))
        guard case let .box(halfExtents, _, _)? = node.physicsShape(.boundingBox) else {
            Issue.record("Expected a box")
            return
        }
        #expect(halfExtents == SIMD3(2, 4, 6))
        guard case let .convexHull(points)? = node.physicsShape(.convexHull) else {
            Issue.record("Expected a hull")
            return
        }
        #expect(points.map(\.y).max() == 4)
        #expect(Node().physicsShape(.convexHull) == nil)
    }

    @Test func removingANodesBody() {
        let scene = Scene()
        let node = Node(geometry: .sphere())
        scene.rootNode.addChild(node)
        let body = node.makePhysicsBody(in: scene.physicsWorld)
        node.removePhysicsBody()
        #expect(node.physicsBody == nil)
        #expect(!body.isValid)
    }
}
#endif
