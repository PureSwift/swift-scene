import SceneCore

/// A scene: a tree of nodes under a root, what is drawn behind them, and the scene's clock.
public final class Scene {

    public let rootNode: Node

    /// What is drawn behind the scene: a colour or a texture.
    public var background: MaterialProperty = .color(SIMD4(0, 0, 0, 1))

    /// A paused scene's actions wait.
    public var isPaused = false

    /// How long the scene has run, unpaused.
    public private(set) var time: Duration = .zero

    /// Transactions' completions, by when they are due.
    var pendingCompletions: [(due: Duration, completion: () -> Void)] = []

    /// What runs with the scene each update, after its actions: a physics world, say.
    public var systems: [any SceneSystem] = []

    public init() {
        self.rootNode = Node(name: "root")
    }

    public convenience init(@NodeBuilder content: () -> [Node]) {
        self.init()
        for node in content() {
            rootNode.addChild(node)
        }
    }

    /// The store the scene's nodes' components are in.
    public var store: EntityStore { rootNode.store }

    /// Moves the scene on by the time: actions run, then systems, then transactions' completions that are due.
    public func update(by delta: Duration) {
        guard !isPaused, delta > .zero else { return }
        time += delta
        rootNode.advanceActions(by: delta)
        for system in systems {
            system.update(self, by: delta)
        }
        guard !pendingCompletions.isEmpty else { return }
        let due = pendingCompletions.filter { $0.due <= time }
        pendingCompletions.removeAll { $0.due <= time }
        for item in due {
            item.completion()
        }
    }

    /// The first node with a camera, depth first.
    public var firstCameraNode: Node? {
        var found: Node?
        rootNode.enumerateHierarchy { node, stop in
            if node.camera != nil {
                found = node
                stop = true
            }
        }
        return found
    }
}

// MARK: - Hit testing

/// Where a ray met a node's geometry.
public struct HitTestResult {

    public let node: Node

    /// How far along the ray, in its direction's lengths.
    public let distance: Float

    /// The point in world space.
    public let worldCoordinates: SIMD3<Float>

    /// The submesh met, and the triangle's first index in it.
    public let submeshIndex: Int

    public let faceIndex: Int
}

public extension Scene {

    /// The visible geometry the ray meets, nearest first.
    func hitTest(_ ray: Ray) -> [HitTestResult] {
        var results: [HitTestResult] = []
        hitTest(ray, node: rootNode, parentWorld: .identity, into: &results)
        return results.sorted { $0.distance < $1.distance }
    }

    private func hitTest(_ ray: Ray, node: Node, parentWorld: Matrix4x4, into results: inout [HitTestResult]) {
        guard !node.isHidden else { return }
        let world = parentWorld * node.transform
        if let geometry = node.geometry, let inverse = world.inverse {
            // Test in the node's space, so the ray's distances carry over unchanged.
            let local = ray.transformed(by: inverse)
            let mesh = geometry.mesh
            if local.intersection(with: mesh.bounds) != nil {
                let positions = mesh.positions
                for (submeshIndex, submesh) in mesh.submeshes.enumerated() {
                    for (faceIndex, triangle) in mesh.triangles(in: submesh).enumerated() {
                        guard let hit = local.intersection(withTriangle: positions[triangle.x], positions[triangle.y], positions[triangle.z]) else { continue }
                        results.append(HitTestResult(
                            node: node,
                            distance: hit.distance,
                            worldCoordinates: ray.point(at: hit.distance),
                            submeshIndex: submeshIndex,
                            faceIndex: faceIndex
                        ))
                    }
                }
            }
        }
        for child in node.children {
            hitTest(ray, node: child, parentWorld: world, into: &results)
        }
    }
}

// MARK: - Systems

/// Something that moves a scene on each update, as a physics world does: modules above `SceneGraph` plug in
/// without it knowing them.
public protocol SceneSystem: AnyObject {

    func update(_ scene: Scene, by delta: Duration)
}
