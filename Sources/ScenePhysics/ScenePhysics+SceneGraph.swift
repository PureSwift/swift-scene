#if canImport(CBox3D)
import SceneCore
import SceneGraph

// SceneKit's physics on SceneGraph's scenes and nodes: a scene's physics world steps as the scene updates, and a
// node's physics body is a `PhysicsBodyComponent` on its entity.

extension PhysicsWorld: SceneSystem {

    public func update(_ scene: Scene, by delta: Duration) {
        step(by: delta, synchronizing: scene.store)
    }
}

public extension Scene {

    /// The world the scene's physics bodies are simulated in, made the first time it's asked for and stepped with
    /// each update.
    var physicsWorld: PhysicsWorld {
        if let world = systems.lazy.compactMap({ $0 as? PhysicsWorld }).first { return world }
        let world = PhysicsWorld()
        systems.append(world)
        return world
    }
}

public extension Node {

    /// The node's body, if it has one.
    var physicsBody: PhysicsBody? {
        store[PhysicsBodyComponent.self, entity]?.body
    }

    /// Gives the node a body in the world, where the node is, with shapes; removes any body it had.
    @discardableResult
    func makePhysicsBody(
        in world: PhysicsWorld,
        type: PhysicsBodyType = .dynamic,
        shape: PhysicsShape.Geometry? = nil,
        material: PhysicsMaterial = PhysicsMaterial()
    ) -> PhysicsBody {
        removePhysicsBody()
        let placed = Transform(matrix: worldTransform)
        let body = world.addBody(PhysicsBodyDescriptor(type: type, position: placed.translation, orientation: placed.rotation))
        if let geometry = shape ?? physicsShape(type == .static ? .concavePolyhedron : .convexHull) {
            body.addShape(geometry, material: material)
        }
        store[PhysicsBodyComponent.self, entity] = PhysicsBodyComponent(body)
        return body
    }

    /// Takes the node's body out of its world.
    func removePhysicsBody() {
        guard let body = store.removeComponent(PhysicsBodyComponent.self, from: entity)?.body else { return }
        body.world?.remove(body)
    }

    /// How a node's geometry becomes a collision shape, as SceneKit's physics shape types do.
    enum PhysicsShapeKind: Sendable {
        /// The geometry's bounding box.
        case boundingBox
        /// The smallest convex shape around the geometry.
        case convexHull
        /// The geometry's triangles as they are: for static bodies.
        case concavePolyhedron
    }

    /// A collision shape from the node's geometry, scaled by the node's own scale; nil without geometry.
    func physicsShape(_ kind: PhysicsShapeKind) -> PhysicsShape.Geometry? {
        guard let mesh = geometry?.mesh, mesh.vertexCount > 0 else { return nil }
        let scale = self.scale
        switch kind {
        case .boundingBox:
            let bounds = mesh.bounds
            return .box(halfExtents: bounds.halfExtents * scale, center: bounds.center * scale)
        case .convexHull:
            return .convexHull(mesh.positions.map { $0 * scale })
        case .concavePolyhedron:
            var scaled = mesh
            if scale != SIMD3(repeating: 1), let index = scaled.streams.firstIndex(where: { $0.semantic == .position }) {
                scaled.streams[index] = VertexStream(semantic: .position, vectors: mesh.positions.map { $0 * scale })
            }
            return .triangleMesh(scaled)
        }
    }
}
#endif
