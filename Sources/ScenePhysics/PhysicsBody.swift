#if canImport(CBox3D)
import CBox3D
import SceneCore

/// How a body moves.
public enum PhysicsBodyType: Hashable, Sendable {
    /// Never moves: the ground, walls.
    case `static`
    /// Moves as it's told, pushing what it meets: platforms, doors.
    case kinematic
    /// Moves by forces and collisions.
    case dynamic

    var box3D: b3BodyType {
        switch self {
        case .static: b3_staticBody
        case .kinematic: b3_kinematicBody
        case .dynamic: b3_dynamicBody
        }
    }

    init(_ type: b3BodyType) {
        switch type {
        case b3_kinematicBody: self = .kinematic
        case b3_dynamicBody: self = .dynamic
        default: self = .static
        }
    }
}

/// How a body starts.
public struct PhysicsBodyDescriptor: Hashable, Sendable {
    public var type: PhysicsBodyType
    public var position: SIMD3<Float>
    public var orientation: Quaternion
    public var linearVelocity: SIMD3<Float>
    public var angularVelocity: SIMD3<Float>
    public var linearDamping: Float
    public var angularDamping: Float
    public var gravityScale: Float
    public var isRotationFixed: Bool
    /// Continuous collision against other moving bodies, for fast small things.
    public var isBullet: Bool

    public init(
        type: PhysicsBodyType = .dynamic,
        position: SIMD3<Float> = .zero,
        orientation: Quaternion = .identity,
        linearVelocity: SIMD3<Float> = .zero,
        angularVelocity: SIMD3<Float> = .zero,
        linearDamping: Float = 0,
        angularDamping: Float = 0,
        gravityScale: Float = 1,
        isRotationFixed: Bool = false,
        isBullet: Bool = false
    ) {
        self.type = type
        self.position = position
        self.orientation = orientation
        self.linearVelocity = linearVelocity
        self.angularVelocity = angularVelocity
        self.linearDamping = linearDamping
        self.angularDamping = angularDamping
        self.gravityScale = gravityScale
        self.isRotationFixed = isRotationFixed
        self.isBullet = isBullet
    }
}

/// A rigid body in a `PhysicsWorld`, with the shapes it collides by.
public final class PhysicsBody {

    /// The world it's in; nil once removed, or once the world is gone.
    public private(set) weak var world: PhysicsWorld?

    private(set) var id: b3BodyId

    /// Its shapes.
    public private(set) var shapes: [PhysicsShape] = []

    init(world: PhysicsWorld, id: b3BodyId) {
        self.world = world
        self.id = id
    }

    /// Whether it's still simulated: in a world that's still there.
    public var isValid: Bool { world != nil && b3Body_IsValid(id) }

    func invalidate() {
        world = nil
        id = b3_nullBodyId
        shapes.removeAll()
    }

    // MARK: Shapes

    /// Gives the body a shape; a dynamic body's mass then comes from its shapes' densities.
    @discardableResult
    public func addShape(_ geometry: PhysicsShape.Geometry, material: PhysicsMaterial = PhysicsMaterial()) -> PhysicsShape? {
        guard isValid, let shape = PhysicsShape(body: self, geometry: geometry, material: material) else { return nil }
        shapes.append(shape)
        return shape
    }

    public func removeShape(_ shape: PhysicsShape) {
        guard let index = shapes.firstIndex(where: { $0 === shape }) else { return }
        shapes.remove(at: index)
        shape.destroy()
    }

    // MARK: State

    public var type: PhysicsBodyType {
        get { isValid ? PhysicsBodyType(b3Body_GetType(id)) : .static }
        set { if isValid { b3Body_SetType(id, newValue.box3D) } }
    }

    public var position: SIMD3<Float> {
        get { isValid ? SIMD3(b3Body_GetPosition(id)) : .zero }
        set { if isValid { b3Body_SetTransform(id, b3Vec3(newValue), b3Body_GetRotation(id)) } }
    }

    public var orientation: Quaternion {
        get { isValid ? Quaternion(b3Body_GetRotation(id)) : .identity }
        set { if isValid { b3Body_SetTransform(id, b3Body_GetPosition(id), b3Quat(newValue.normalized)) } }
    }

    /// The body's place as a transform: its position and orientation, at unit scale.
    public var transform: Transform {
        get { Transform(rotation: orientation, translation: position) }
        set { if isValid { b3Body_SetTransform(id, b3Vec3(newValue.translation), b3Quat(newValue.rotation.normalized)) } }
    }

    public var linearVelocity: SIMD3<Float> {
        get { isValid ? SIMD3(b3Body_GetLinearVelocity(id)) : .zero }
        set { if isValid { b3Body_SetLinearVelocity(id, b3Vec3(newValue)) } }
    }

    public var angularVelocity: SIMD3<Float> {
        get { isValid ? SIMD3(b3Body_GetAngularVelocity(id)) : .zero }
        set { if isValid { b3Body_SetAngularVelocity(id, b3Vec3(newValue)) } }
    }

    public var mass: Float { isValid ? b3Body_GetMass(id) : 0 }

    public var linearDamping: Float {
        get { isValid ? b3Body_GetLinearDamping(id) : 0 }
        set { if isValid { b3Body_SetLinearDamping(id, newValue) } }
    }

    public var angularDamping: Float {
        get { isValid ? b3Body_GetAngularDamping(id) : 0 }
        set { if isValid { b3Body_SetAngularDamping(id, newValue) } }
    }

    public var isAwake: Bool {
        get { isValid && b3Body_IsAwake(id) }
        set { if isValid { b3Body_SetAwake(id, newValue) } }
    }

    // MARK: Forces

    /// A force through the center of mass, for the next step.
    public func applyForce(_ force: SIMD3<Float>, wake: Bool = true) {
        if isValid { b3Body_ApplyForceToCenter(id, b3Vec3(force), wake) }
    }

    /// A force at a point in world space, turning the body as well as pushing it.
    public func applyForce(_ force: SIMD3<Float>, at point: SIMD3<Float>, wake: Bool = true) {
        if isValid { b3Body_ApplyForce(id, b3Vec3(force), b3Vec3(point), wake) }
    }

    public func applyTorque(_ torque: SIMD3<Float>, wake: Bool = true) {
        if isValid { b3Body_ApplyTorque(id, b3Vec3(torque), wake) }
    }

    /// An instant change of momentum through the center of mass.
    public func applyImpulse(_ impulse: SIMD3<Float>, wake: Bool = true) {
        if isValid { b3Body_ApplyLinearImpulseToCenter(id, b3Vec3(impulse), wake) }
    }

    public func applyImpulse(_ impulse: SIMD3<Float>, at point: SIMD3<Float>, wake: Bool = true) {
        if isValid { b3Body_ApplyLinearImpulse(id, b3Vec3(impulse), b3Vec3(point), wake) }
    }

    public func applyAngularImpulse(_ impulse: SIMD3<Float>, wake: Bool = true) {
        if isValid { b3Body_ApplyAngularImpulse(id, b3Vec3(impulse), wake) }
    }
}
#endif
