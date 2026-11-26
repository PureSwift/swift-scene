/// Entities and their components: the storage `SceneGraph`'s nodes and `SceneReality`'s entities both keep
/// their state in. Any type can be a component; each type has its own `ComponentStorage`.
///
/// A store belongs to one isolation domain: it is not `Sendable`.
public final class EntityStore {

    /// Each slot's current generation; a slot's entity is alive while its identifier's generation matches.
    private var generations: [UInt32] = []

    /// Whether each slot holds a live entity.
    private var occupied: [Bool] = []

    /// Slots free for reuse.
    private var freeSlots: [UInt32] = []

    private var storages: [ObjectIdentifier: any AnyStorageBox] = [:]

    public private(set) var entityCount = 0

    public init() {}

    // MARK: Entities

    public func createEntity() -> EntityID {
        entityCount += 1
        if let index = freeSlots.popLast() {
            occupied[Int(index)] = true
            return EntityID(index: index, generation: generations[Int(index)])
        }
        let index = UInt32(generations.count)
        generations.append(0)
        occupied.append(true)
        return EntityID(index: index, generation: 0)
    }

    public func isAlive(_ entity: EntityID) -> Bool {
        let index = Int(entity.index)
        return index < generations.count && occupied[index] && generations[index] == entity.generation
    }

    /// Removes the entity and all its components; its identifier is never alive again.
    public func destroy(_ entity: EntityID) {
        guard isAlive(entity) else { return }
        for storage in storages.values { storage.remove(entity) }
        let index = Int(entity.index)
        generations[index] &+= 1
        occupied[index] = false
        freeSlots.append(entity.index)
        entityCount -= 1
    }

    /// Moves the entity and its components to another store, where it has a new identifier.
    public func transfer(_ entity: EntityID, to other: EntityStore) -> EntityID {
        guard other !== self else { return entity }
        let moved = other.createEntity()
        guard isAlive(entity) else { return moved }
        for storage in storages.values { storage.transfer(entity, to: moved, in: other) }
        destroy(entity)
        return moved
    }

    // MARK: Components

    private func box<C>(_ type: C.Type) -> StorageBox<C> {
        let key = ObjectIdentifier(type)
        if let box = storages[key] { return unsafeDowncast(box, to: StorageBox<C>.self) }
        let box = StorageBox<C>()
        storages[key] = box
        return box
    }

    /// The entity's component of a type; setting nil removes it. Setting one on a dead entity does nothing.
    public subscript<C>(_ type: C.Type, entity: EntityID) -> C? {
        get {
            storages[ObjectIdentifier(type)].flatMap { unsafeDowncast($0, to: StorageBox<C>.self).storage[entity] }
        }
        set {
            guard newValue == nil || isAlive(entity) else { return }
            box(type).storage[entity] = newValue
        }
    }

    public func hasComponent<C>(_ type: C.Type, for entity: EntityID) -> Bool {
        storages[ObjectIdentifier(type)].map { unsafeDowncast($0, to: StorageBox<C>.self).storage.contains(entity) } ?? false
    }

    @discardableResult
    public func removeComponent<C>(_ type: C.Type, from entity: EntityID) -> C? {
        storages[ObjectIdentifier(type)].flatMap { unsafeDowncast($0, to: StorageBox<C>.self).storage.remove(entity) }
    }

    /// Changes the entity's component in place, if it has one.
    @discardableResult
    public func modify<C, R>(_ type: C.Type, of entity: EntityID, _ body: (inout C) throws -> R) rethrows -> R? {
        guard let box = storages[ObjectIdentifier(type)] else { return nil }
        return try unsafeDowncast(box, to: StorageBox<C>.self).storage.modify(entity, body)
    }

    /// All the components of a type.
    public func storage<C>(_ type: C.Type) -> ComponentStorage<C> {
        storages[ObjectIdentifier(type)].map { unsafeDowncast($0, to: StorageBox<C>.self).storage } ?? ComponentStorage()
    }

    /// Works on all the components of a type in place, as a system does.
    public func withStorage<C, R>(_ type: C.Type, _ body: (inout ComponentStorage<C>) throws -> R) rethrows -> R {
        try body(&box(type).storage)
    }
}

// MARK: - Storage boxes

/// A component storage of some type, for what the store does to every type at once.
private protocol AnyStorageBox: AnyObject {
    func remove(_ entity: EntityID)
    func transfer(_ entity: EntityID, to moved: EntityID, in other: EntityStore)
}

private final class StorageBox<C>: AnyStorageBox {

    var storage = ComponentStorage<C>()

    func remove(_ entity: EntityID) {
        storage.remove(entity)
    }

    func transfer(_ entity: EntityID, to moved: EntityID, in other: EntityStore) {
        if let component = storage.remove(entity) {
            other[C.self, moved] = component
        }
    }
}
