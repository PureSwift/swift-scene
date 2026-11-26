import SceneCore

/// A place in a scene: a transform within its parent, what it shows (a geometry, a light, a camera), and
/// its children.
///
/// A node is an entity in a `SceneCore.EntityStore`: its transform, its parent and its visibility are
/// components there, which renderers and systems read directly. A node made on its own has a store of its
/// own; added to another node, it and its descendants move to that node's store.
public final class Node {

    /// The store the node's components are in.
    public private(set) var store: EntityStore

    /// The node's entity in `store`.
    public private(set) var entity: EntityID

    public var name: String?

    public var geometry: Geometry?

    public var light: Light?

    public var camera: Camera?

    public private(set) weak var parent: Node?

    public private(set) var children: [Node] = []

    /// The Euler angles the rotation was last set by, which read back as they were given.
    private var eulerAnglesAsSet: SIMD3<Float>?

    /// The actions running on the node.
    var runningActions: [RunningAction] = []

    /// A paused node's actions, and those of the nodes below it, wait.
    public var isPaused = false

    public init(name: String? = nil, geometry: Geometry? = nil) {
        let store = EntityStore()
        self.store = store
        self.entity = store.createEntity()
        self.name = name
        self.geometry = geometry
        store[LocalTransform.self, entity] = LocalTransform()
        store[Visibility.self, entity] = Visibility()
    }

    deinit {
        store.destroy(entity)
    }

    // MARK: Transform

    /// The node's transform and pivot, as kept in the store.
    public var localTransform: LocalTransform {
        get { store[LocalTransform.self, entity] ?? LocalTransform() }
        set { store[LocalTransform.self, entity] = newValue }
    }

    public var position: SIMD3<Float> {
        get { localTransform.transform.translation }
        set { store.modify(LocalTransform.self, of: entity) { $0.transform.translation = newValue } }
    }

    public var orientation: Quaternion {
        get { localTransform.transform.rotation }
        set {
            store.modify(LocalTransform.self, of: entity) { $0.transform.rotation = newValue.normalized }
            eulerAnglesAsSet = nil
        }
    }

    /// The rotation as an axis (x, y, z) and an angle (w).
    public var rotation: SIMD4<Float> {
        get {
            let q = orientation
            return SIMD4(q.axis, q.angle)
        }
        set { orientation = Quaternion(angle: newValue.w, axis: newValue.xyz) }
    }

    /// The rotation as pitch, yaw and roll, in SceneKit's order. Angles set read back as they were given.
    public var eulerAngles: SIMD3<Float> {
        get { eulerAnglesAsSet ?? orientation.eulerAngles(sceneKitReadBack: true) }
        set {
            orientation = Quaternion(eulerAngles: newValue)
            eulerAnglesAsSet = newValue
        }
    }

    public var scale: SIMD3<Float> {
        get { localTransform.transform.scale }
        set { store.modify(LocalTransform.self, of: entity) { $0.transform.scale = newValue } }
    }

    /// The point and axes, in the node's own space, it is placed, turned and scaled about.
    public var pivot: Matrix4x4 {
        get { localTransform.pivot ?? .identity }
        set { store.modify(LocalTransform.self, of: entity) { $0.pivot = newValue == .identity ? nil : newValue } }
    }

    /// The node's transform within its parent. Setting it takes it apart into position, rotation and scale,
    /// and clears the pivot.
    public var transform: Matrix4x4 {
        get { localTransform.matrix }
        set {
            localTransform = LocalTransform(transform: Transform(matrix: newValue))
            eulerAnglesAsSet = nil
        }
    }

    /// The node's transform in the scene: its ancestors' times its own.
    public var worldTransform: Matrix4x4 {
        store.worldMatrix(of: entity)
    }

    public var worldPosition: SIMD3<Float> {
        get { worldTransform.translation }
        set {
            let parentWorld = parent?.worldTransform ?? .identity
            position = (parentWorld.inverse ?? .identity).transformPoint(newValue)
        }
    }

    /// A point in this node's space, in another node's, or the scene's for nil.
    public func convertPosition(_ position: SIMD3<Float>, to node: Node?) -> SIMD3<Float> {
        let inScene = worldTransform.transformPoint(position)
        guard let node else { return inScene }
        return (node.worldTransform.inverse ?? .identity).transformPoint(inScene)
    }

    /// A point in another node's space, or the scene's for nil, in this node's.
    public func convertPosition(_ position: SIMD3<Float>, from node: Node?) -> SIMD3<Float> {
        let inScene = node.map { $0.worldTransform.transformPoint(position) } ?? position
        return (worldTransform.inverse ?? .identity).transformPoint(inScene)
    }

    /// Turns the node so its -z axis points at a point in its parent's space.
    public func look(at target: SIMD3<Float>, up: SIMD3<Float> = SIMD3(0, 1, 0)) {
        let view = Matrix4x4.lookAt(eye: position, target: target, up: up)
        guard let world = view.inverse else { return }
        orientation = Quaternion(rotationMatrix: world)
    }

    // MARK: Visibility

    public var visibility: Visibility {
        get { store[Visibility.self, entity] ?? Visibility() }
        set { store[Visibility.self, entity] = newValue }
    }

    public var isHidden: Bool {
        get { visibility.isHidden }
        set { store.modify(Visibility.self, of: entity) { $0.isHidden = newValue } }
    }

    public var opacity: Float {
        get { visibility.opacity }
        set { store.modify(Visibility.self, of: entity) { $0.opacity = newValue } }
    }

    public var categoryBitMask: Int {
        get { visibility.categoryBitMask }
        set { store.modify(Visibility.self, of: entity) { $0.categoryBitMask = newValue } }
    }

    // MARK: Tree

    /// Adds a child last. A node has one parent: adding it somewhere else moves it. Adding the node or one of
    /// its ancestors does nothing.
    public func addChild(_ child: Node) {
        insertChild(child, at: children.count)
    }

    public func insertChild(_ child: Node, at index: Int) {
        guard child !== self, !isDescendant(of: child) else { return }
        child.removeFromParent()
        if child.store !== store {
            child.move(to: store)
        }
        child.parent = self
        store[Parent.self, child.entity] = Parent(entity)
        children.insert(child, at: min(max(index, 0), children.count))
    }

    public func removeFromParent() {
        guard let parent else { return }
        parent.children.removeAll { $0 === self }
        store.removeComponent(Parent.self, from: entity)
        self.parent = nil
    }

    public func replaceChild(_ old: Node, with new: Node) {
        guard let index = children.firstIndex(where: { $0 === old }) else { return }
        old.removeFromParent()
        insertChild(new, at: index)
    }

    /// Whether `ancestor` is this node or above it.
    public func isDescendant(of ancestor: Node) -> Bool {
        var current: Node? = self
        while let node = current {
            if node === ancestor { return true }
            current = node.parent
        }
        return false
    }

    /// The first child with the name, or the first below in depth-first order.
    public func childNode(named name: String, recursively: Bool = true) -> Node? {
        for child in children {
            if child.name == name { return child }
            if recursively, let found = child.childNode(named: name, recursively: true) { return found }
        }
        return nil
    }

    /// The nodes below that pass the test, depth first.
    public func childNodes(passingTest test: (Node) -> Bool) -> [Node] {
        var found: [Node] = []
        enumerateHierarchy { node, _ in
            if node !== self, test(node) { found.append(node) }
        }
        return found
    }

    /// Visits the node and every node below, depth first, parents first; setting `stop` ends the walk.
    public func enumerateHierarchy(_ body: (Node, inout Bool) -> Void) {
        var stop = false
        enumerate(body, stop: &stop)
    }

    private func enumerate(_ body: (Node, inout Bool) -> Void, stop: inout Bool) {
        body(self, &stop)
        for child in children {
            guard !stop else { return }
            child.enumerate(body, stop: &stop)
        }
    }

    /// Moves the node and its descendants to another store.
    private func move(to newStore: EntityStore) {
        entity = store.transfer(entity, to: newStore)
        store = newStore
        for child in children {
            child.move(to: newStore)
            newStore[Parent.self, child.entity] = Parent(entity)
        }
    }

    // MARK: Bounds

    /// The geometry's bounds in the node's space; empty with none.
    public var boundingBox: BoundingBox {
        geometry?.boundingBox ?? .empty
    }

    /// The bounds of the node's geometry and every geometry below, in the node's space.
    public var hierarchyBoundingBox: BoundingBox {
        var box = boundingBox
        for child in children {
            box.formUnion(child.hierarchyBoundingBox.transformed(by: child.transform))
        }
        return box
    }

    // MARK: Copying

    /// A copy of the node and its descendants, sharing their geometries, lights and cameras; actions are not copied.
    public func clone() -> Node {
        let copy = Node(name: name, geometry: geometry)
        copy.light = light
        copy.camera = camera
        copy.localTransform = localTransform
        copy.visibility = visibility
        copy.eulerAnglesAsSet = eulerAnglesAsSet
        for child in children {
            copy.addChild(child.clone())
        }
        return copy
    }
}

extension Node: CustomStringConvertible {

    public var description: String {
        "Node(\(name.map { "\"\($0)\"" } ?? "unnamed"), \(entity), children: \(children.count))"
    }
}
