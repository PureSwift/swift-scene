#if canImport(CBox3D)
import SceneCore

/// Ties an entity to a body, so the simulation and the entity's transform agree.
///
/// A dynamic body moves its entity; a kinematic or static one follows its entity. Transforms are in the space of
/// the entity's parent, which for physics is the world: bodies belong on entities without a moving parent.
public struct PhysicsBodyComponent {

    public let body: PhysicsBody

    public init(_ body: PhysicsBody) {
        self.body = body
    }
}

public extension PhysicsWorld {

    /// Moves bodies that follow their entities to where the entities are: before a step.
    func readTransforms(from store: EntityStore) {
        store.withStorage(PhysicsBodyComponent.self) { storage in
            for (entity, component) in storage where component.body.type != .dynamic {
                guard let local = store[LocalTransform.self, entity] else { continue }
                component.body.transform = Transform(rotation: local.transform.rotation, translation: local.transform.translation)
            }
        }
    }

    /// Moves entities to where their dynamic bodies are, keeping each entity's scale: after a step.
    func writeTransforms(to store: EntityStore) {
        store.withStorage(PhysicsBodyComponent.self) { storage in
            for (entity, component) in storage where component.body.type == .dynamic && component.body.isValid {
                let placed = component.body.transform
                store.modify(LocalTransform.self, of: entity) { local in
                    local.transform.translation = placed.translation
                    local.transform.rotation = placed.rotation
                }
            }
        }
    }

    /// Reads kinematic and static bodies from the store, steps, and writes dynamic bodies back.
    func step(by timeStep: Duration, subSteps: Int = 4, synchronizing store: EntityStore) {
        readTransforms(from: store)
        step(by: timeStep, subSteps: subSteps)
        writeTransforms(to: store)
    }
}
#endif
