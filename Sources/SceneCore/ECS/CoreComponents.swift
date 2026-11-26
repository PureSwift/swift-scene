/// An entity's transform within its parent's space, and a pivot: the point and axes, in the entity's own
/// space, that it is placed, turned and scaled about.
public struct LocalTransform: Hashable, Sendable {

    public var transform: Transform

    /// Nil for none: the entity's origin and axes.
    public var pivot: Matrix4x4?

    public init(transform: Transform = .identity, pivot: Matrix4x4? = nil) {
        self.transform = transform
        self.pivot = pivot
    }

    /// The transform, then the pivot undone.
    public var matrix: Matrix4x4 {
        let placed = transform.matrix
        guard let pivot, pivot != .identity else { return placed }
        return placed * (pivot.inverse ?? .identity)
    }
}

/// The entity an entity's transform is relative to.
public struct Parent: Hashable, Sendable {

    public var entity: EntityID

    public init(_ entity: EntityID) {
        self.entity = entity
    }
}

/// Whether an entity is drawn, and how opaque, which its descendants inherit.
public struct Visibility: Hashable, Sendable {

    public var isHidden: Bool

    public var opacity: Float

    /// Which lights, cameras and passes the entity takes part in.
    public var categoryBitMask: Int

    public init(isHidden: Bool = false, opacity: Float = 1, categoryBitMask: Int = 1) {
        self.isHidden = isHidden
        self.opacity = opacity
        self.categoryBitMask = categoryBitMask
    }
}

public extension EntityStore {

    /// The entity's transform in world space: each parent's local transform times its own, up the chain.
    /// An entity with no local transform counts as the identity; the chain stops at a parent that is gone.
    func worldMatrix(of entity: EntityID) -> Matrix4x4 {
        var matrix = self[LocalTransform.self, entity]?.matrix ?? .identity
        var current = self[Parent.self, entity]?.entity
        var depth = 0
        while let parent = current, isAlive(parent), depth < 1 << 16 {
            if let local = self[LocalTransform.self, parent] {
                matrix = local.matrix * matrix
            }
            current = self[Parent.self, parent]?.entity
            depth += 1
        }
        return matrix
    }
}
