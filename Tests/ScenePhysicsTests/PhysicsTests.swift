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
