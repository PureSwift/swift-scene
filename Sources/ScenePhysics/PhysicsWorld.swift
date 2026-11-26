#if canImport(CBox3D)
import CBox3D
import SceneCore
import Synchronization

/// Box3D keeps its worlds in a global table that two threads mustn't change at once.
private let worldTable = Mutex(())

/// A simulated world of rigid bodies, over Box3D.
///
/// The world owns its bodies: one stays in the simulation until it's removed, whether or not anything else holds
/// it, as an entity in a scene does. A world, its bodies and their shapes belong to one isolation domain; separate
/// worlds may be made and stepped on separate threads.
public final class PhysicsWorld {

    let id: b3WorldId

    /// The bodies in the world.
    public private(set) var bodies: [PhysicsBody] = []

    /// The joints between its bodies.
    public private(set) var joints: [PhysicsJoint] = []

    /// Bodies by their Box3D identifiers, to answer events and queries with.
    private var bodiesByKey: [BodyKey: PhysicsBody] = [:]

    /// A world; `workerCount` above 1 steps on that many threads.
    public init(gravity: SIMD3<Float> = SIMD3(0, -9.8, 0), workerCount: Int = 1) {
        var def = b3DefaultWorldDef()
        def.gravity = b3Vec3(gravity)
        def.workerCount = UInt32(max(workerCount, 1))
        id = worldTable.withLock { _ in b3CreateWorld(&def) }
    }

    deinit {
        // The bodies' shapes may reference mesh data their wrappers own, which goes after this.
        worldTable.withLock { _ in b3DestroyWorld(id) }
    }

    public var gravity: SIMD3<Float> {
        get { SIMD3(b3World_GetGravity(id)) }
        set { b3World_SetGravity(id, b3Vec3(newValue)) }
    }

    /// Whether resting bodies stop being simulated until something touches them.
    public var isSleepingEnabled: Bool {
        get { b3World_IsSleepingEnabled(id) }
        set { b3World_EnableSleeping(id, newValue) }
    }

    /// Moves the simulation on by the time, in `subSteps` solver steps.
    public func step(by timeStep: Duration, subSteps: Int = 4) {
        let parts = timeStep.components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) * 1e-18
        step(seconds: Float(seconds), subSteps: subSteps)
    }

    public func step(seconds: Float, subSteps: Int = 4) {
        guard seconds > 0 else { return }
        b3World_Step(id, seconds, Int32(max(subSteps, 1)))
    }

    // MARK: Bodies

    /// Adds a body.
    @discardableResult
    public func addBody(_ descriptor: PhysicsBodyDescriptor = PhysicsBodyDescriptor()) -> PhysicsBody {
        var def = b3DefaultBodyDef()
        def.type = descriptor.type.box3D
        def.position = b3Vec3(descriptor.position)
        def.rotation = b3Quat(descriptor.orientation)
        def.linearVelocity = b3Vec3(descriptor.linearVelocity)
        def.angularVelocity = b3Vec3(descriptor.angularVelocity)
        def.linearDamping = descriptor.linearDamping
        def.angularDamping = descriptor.angularDamping
        def.gravityScale = descriptor.gravityScale
        def.fixedRotation = descriptor.isRotationFixed
        def.isBullet = descriptor.isBullet
        let body = PhysicsBody(world: self, id: b3CreateBody(id, &def))
        bodies.append(body)
        bodiesByKey[BodyKey(body.id)] = body
        return body
    }

    /// Takes a body and its shapes out of the world.
    public func remove(_ body: PhysicsBody) {
        guard body.world === self, bodiesByKey.removeValue(forKey: BodyKey(body.id)) != nil else { return }
        bodies.removeAll { $0 === body }
        // Box3D takes a body's joints with it.
        for joint in joints where joint.bodyA === body || joint.bodyB === body {
            joint.invalidate()
        }
        joints.removeAll { !$0.isValid }
        if b3Body_IsValid(body.id) { b3DestroyBody(body.id) }
        body.invalidate()
    }

    func appendJoint(_ joint: PhysicsJoint) {
        joints.append(joint)
    }

    func unregister(_ joint: PhysicsJoint) {
        joints.removeAll { $0 === joint }
    }

    func body(for id: b3BodyId) -> PhysicsBody? {
        bodiesByKey[BodyKey(id)]
    }

    func body(forShape shapeId: b3ShapeId) -> PhysicsBody? {
        guard b3Shape_IsValid(shapeId) else { return nil }
        return body(for: b3Shape_GetBody(shapeId))
    }

    // MARK: Queries

    /// The first shape a ray from `origin` along `translation` meets, if any.
    public func castRay(from origin: SIMD3<Float>, along translation: SIMD3<Float>) -> PhysicsRayHit? {
        let result = b3World_CastRayClosest(id, b3Vec3(origin), b3Vec3(translation), b3DefaultQueryFilter())
        guard result.hit, let body = body(forShape: result.shapeId) else { return nil }
        return PhysicsRayHit(body: body, point: SIMD3(result.point), normal: SIMD3(result.normal), fraction: result.fraction)
    }

    // MARK: Events

    /// The pairs of bodies whose shapes began touching in the last step, for shapes with contact events enabled.
    public var contactsBegun: [(PhysicsBody, PhysicsBody)] {
        let events = b3World_GetContactEvents(id)
        guard events.beginCount > 0, let begun = events.beginEvents else { return [] }
        return (0 ..< Int(events.beginCount)).compactMap { i in
            guard let a = body(forShape: begun[i].shapeIdA), let b = body(forShape: begun[i].shapeIdB) else { return nil }
            return (a, b)
        }
    }

    /// The pairs of bodies whose shapes stopped touching in the last step.
    public var contactsEnded: [(PhysicsBody, PhysicsBody)] {
        let events = b3World_GetContactEvents(id)
        guard events.endCount > 0, let ended = events.endEvents else { return [] }
        return (0 ..< Int(events.endCount)).compactMap { i in
            guard let a = body(forShape: ended[i].shapeIdA), let b = body(forShape: ended[i].shapeIdB) else { return nil }
            return (a, b)
        }
    }
}

/// Where a ray met a body.
public struct PhysicsRayHit {
    public let body: PhysicsBody
    public let point: SIMD3<Float>
    public let normal: SIMD3<Float>
    /// How far along the ray, from 0 to 1.
    public let fraction: Float
}

/// A Box3D body identifier as a dictionary key.
struct BodyKey: Hashable {
    let index: Int32
    let world: UInt16
    let generation: UInt16

    init(_ id: b3BodyId) {
        index = id.index1
        world = id.world0
        generation = id.generation
    }
}
#endif
