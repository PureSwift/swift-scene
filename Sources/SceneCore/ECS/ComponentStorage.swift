/// One type of component, for any number of entities, as a sparse set: a sparse array from entity index to a
/// slot in dense, packed arrays of entities and their components, so iteration touches only what is there
/// and lookup, insertion and removal take constant time.
public struct ComponentStorage<Component> {

    /// The dense slot of each entity index, or -1.
    private var sparse: [Int32] = []

    /// The entities that have the component, packed, in the order of `components`.
    public private(set) var entities: [EntityID] = []

    /// The components, packed.
    public private(set) var components: [Component] = []

    public init() {}

    public var count: Int { components.count }

    public var isEmpty: Bool { components.isEmpty }

    private func slot(of entity: EntityID) -> Int? {
        let index = Int(entity.index)
        guard index < sparse.count else { return nil }
        let slot = Int(sparse[index])
        guard slot >= 0, entities[slot] == entity else { return nil }
        return slot
    }

    public func contains(_ entity: EntityID) -> Bool {
        slot(of: entity) != nil
    }

    /// The entity's component; setting nil removes it.
    public subscript(entity: EntityID) -> Component? {
        get { slot(of: entity).map { components[$0] } }
        set {
            if let newValue {
                insert(newValue, for: entity)
            } else {
                remove(entity)
            }
        }
    }

    /// Gives the entity the component, replacing any it had.
    public mutating func insert(_ component: Component, for entity: EntityID) {
        if let slot = slot(of: entity) {
            components[slot] = component
            return
        }
        let index = Int(entity.index)
        if index >= sparse.count {
            sparse.append(contentsOf: repeatElement(-1, count: index - sparse.count + 1))
        }
        // A stale entity of the same index loses its component to the new one.
        let stale = Int(sparse[index])
        if stale >= 0 {
            entities[stale] = entity
            components[stale] = component
            return
        }
        sparse[index] = Int32(components.count)
        entities.append(entity)
        components.append(component)
    }

    /// Takes the entity's component away, moving the last into its slot.
    @discardableResult
    public mutating func remove(_ entity: EntityID) -> Component? {
        guard let slot = slot(of: entity) else { return nil }
        let removed = components[slot]
        let last = components.count - 1
        if slot != last {
            entities[slot] = entities[last]
            components[slot] = components[last]
            sparse[Int(entities[slot].index)] = Int32(slot)
        }
        entities.removeLast()
        components.removeLast()
        sparse[Int(entity.index)] = -1
        return removed
    }

    /// Changes the entity's component in place, if it has one.
    @discardableResult
    public mutating func modify<R>(_ entity: EntityID, _ body: (inout Component) throws -> R) rethrows -> R? {
        guard let slot = slot(of: entity) else { return nil }
        return try body(&components[slot])
    }

    /// Changes every component in place.
    public mutating func modifyAll(_ body: (EntityID, inout Component) throws -> Void) rethrows {
        for slot in components.indices {
            try body(entities[slot], &components[slot])
        }
    }

    public mutating func removeAll() {
        sparse.removeAll()
        entities.removeAll()
        components.removeAll()
    }
}

extension ComponentStorage: Sequence {

    public struct Iterator: IteratorProtocol {
        fileprivate var entities: IndexingIterator<[EntityID]>
        fileprivate var components: IndexingIterator<[Component]>

        public mutating func next() -> (entity: EntityID, component: Component)? {
            guard let entity = entities.next(), let component = components.next() else { return nil }
            return (entity, component)
        }
    }

    public func makeIterator() -> Iterator {
        Iterator(entities: entities.makeIterator(), components: components.makeIterator())
    }

    public var underestimatedCount: Int { count }
}

extension ComponentStorage: Sendable where Component: Sendable {}
