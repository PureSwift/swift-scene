#if canImport(CBox3D)
import SceneCore

/// Ties an entity to a body, so the simulation and the entity's transform agree.
///
/// A dynamic body moves its entity; a kinematic or static one follows its entity. Bodies live in world space, and
/// entities in their parents': the two are converted through the parent's world transform, so a body may be on an
/// entity anywhere in a hierarchy. An entity's own scale is its own: bodies don't scale.
public struct PhysicsBodyComponent {

    public let body: PhysicsBody

    public init(_ body: PhysicsBody) {
        self.body = body
    }
}

public extension PhysicsWorld {

    /// Moves bodies that follow their entities to where the entities are in the world: before a step.
    func readTransforms(from store: EntityStore) {
        store.withStorage(PhysicsBodyComponent.self) { storage in
            for (entity, component) in storage where component.body.type != .dynamic && component.body.isValid {
                let world = Transform(matrix: store.worldMatrix(of: entity))
                component.body.transform = Transform(rotation: world.rotation, translation: world.translation)
            }
        }
    }

    /// Moves entities to where their dynamic bodies are, in their parents' space: after a step.
    func writeTransforms(to store: EntityStore) {
        store.withStorage(PhysicsBodyComponent.self) { storage in
            for (entity, component) in storage where component.body.type == .dynamic && component.body.isValid {
                var placed = component.body.transform.matrix
                if let parent = store[Parent.self, entity]?.entity, store.isAlive(parent) {
                    placed = (store.worldMatrix(of: parent).inverse ?? .identity) * placed
                }
                let local = Transform(matrix: placed)
                store.modify(LocalTransform.self, of: entity) {
                    $0.transform.translation = local.translation
                    $0.transform.rotation = local.rotation
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
