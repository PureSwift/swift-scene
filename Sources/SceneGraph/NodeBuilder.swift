import SceneCore

/// Builds a list of nodes declaratively.
///
/// ```swift
/// let scene = Scene {
///     Node(name: "camera").camera(Camera()).positioned(at: [0, 1, 6])
///     Node(name: "box", geometry: .box()) {
///         Node(geometry: .sphere(radius: 0.25)).positioned(at: [0, 1, 0])
///     }
/// }
/// ```
@resultBuilder
public enum NodeBuilder {

    public static func buildExpression(_ node: Node) -> [Node] { [node] }

    public static func buildExpression(_ nodes: [Node]) -> [Node] { nodes }

    public static func buildBlock(_ components: [Node]...) -> [Node] { components.flatMap { $0 } }

    public static func buildOptional(_ component: [Node]?) -> [Node] { component ?? [] }

    public static func buildEither(first component: [Node]) -> [Node] { component }

    public static func buildEither(second component: [Node]) -> [Node] { component }

    public static func buildArray(_ components: [[Node]]) -> [Node] { components.flatMap { $0 } }

    public static func buildLimitedAvailability(_ component: [Node]) -> [Node] { component }
}

public extension Node {

    convenience init(name: String? = nil, geometry: Geometry? = nil, @NodeBuilder children: () -> [Node]) {
        self.init(name: name, geometry: geometry)
        for child in children() {
            addChild(child)
        }
    }

    // Modifiers, each changing the node and giving it back, for building trees in one expression.

    @discardableResult
    func positioned(at position: SIMD3<Float>) -> Node {
        self.position = position
        return self
    }

    @discardableResult
    func oriented(_ orientation: Quaternion) -> Node {
        self.orientation = orientation
        return self
    }

    @discardableResult
    func scaled(_ scale: SIMD3<Float>) -> Node {
        self.scale = scale
        return self
    }

    @discardableResult
    func looking(at target: SIMD3<Float>, up: SIMD3<Float> = SIMD3(0, 1, 0)) -> Node {
        look(at: target, up: up)
        return self
    }

    @discardableResult
    func camera(_ camera: Camera?) -> Node {
        self.camera = camera
        return self
    }

    @discardableResult
    func light(_ light: Light?) -> Node {
        self.light = light
        return self
    }

    @discardableResult
    func hidden(_ isHidden: Bool = true) -> Node {
        self.isHidden = isHidden
        return self
    }

    @discardableResult
    func opacity(_ opacity: Float) -> Node {
        self.opacity = opacity
        return self
    }

    @discardableResult
    func running(_ action: Action, forKey key: String? = nil) -> Node {
        runAction(action, forKey: key)
        return self
    }
}
