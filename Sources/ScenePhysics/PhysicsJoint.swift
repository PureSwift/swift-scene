#if canImport(CBox3D)
import CBox3D
import SceneCore

/// A constraint between two bodies.
///
/// Anchors and axes are in each body's own space, as SceneKit's joints take them. The world owns its joints: a
/// joint lasts until it's removed, or until either of its bodies is.
public class PhysicsJoint {

    /// The world it's in; nil once removed.
    public private(set) weak var world: PhysicsWorld?

    public let bodyA: PhysicsBody
    public let bodyB: PhysicsBody

    private(set) var id: b3JointId

    init(world: PhysicsWorld, id: b3JointId, bodyA: PhysicsBody, bodyB: PhysicsBody) {
        self.world = world
        self.id = id
        self.bodyA = bodyA
        self.bodyB = bodyB
    }

    public var isValid: Bool { world != nil && b3Joint_IsValid(id) }

    func invalidate() {
        world = nil
        id = b3_nullJointId
    }

    /// Whether the two bodies still collide with each other.
    public var collidesConnected: Bool {
        get { isValid && b3Joint_GetCollideConnected(id) }
        set { if isValid { b3Joint_SetCollideConnected(id, newValue) } }
    }

    /// The force the joint applied to body B in the last step.
    public var constraintForce: SIMD3<Float> { isValid ? SIMD3(b3Joint_GetConstraintForce(id)) : .zero }

    /// The torque the joint applied to body B in the last step.
    public var constraintTorque: SIMD3<Float> { isValid ? SIMD3(b3Joint_GetConstraintTorque(id)) : .zero }
}

/// A motor driving a joint toward a speed, with at most so much force or torque.
public struct JointMotor: Hashable, Sendable {
    /// Radians a second for a hinge, units a second for a slider or distance joint.
    public var speed: Float
    /// Newton-metres for a hinge, newtons otherwise.
    public var maximumForce: Float

    public init(speed: Float, maximumForce: Float) {
        self.speed = speed
        self.maximumForce = maximumForce
    }
}

/// Bodies turning about a shared axis: a door, a wheel on an axle.
public final class HingeJoint: PhysicsJoint {

    /// How far body B has turned from where it started, in radians.
    public var angle: Float { isValid ? b3RevoluteJoint_GetAngle(id) : 0 }

    /// The range it may turn through, in radians; nil for any.
    public var limits: ClosedRange<Float>? {
        didSet {
            guard isValid else { return }
            b3RevoluteJoint_EnableLimit(id, limits != nil)
            if let limits { b3RevoluteJoint_SetLimits(id, limits.lowerBound, limits.upperBound) }
        }
    }

    public var motor: JointMotor? {
        didSet {
            guard isValid else { return }
            b3RevoluteJoint_EnableMotor(id, motor != nil)
            if let motor {
                b3RevoluteJoint_SetMotorSpeed(id, motor.speed)
                b3RevoluteJoint_SetMaxMotorTorque(id, motor.maximumForce)
            }
        }
    }
}

/// Bodies sliding along a shared axis: a drawer, a piston.
public final class SliderJoint: PhysicsJoint {

    /// How far body B has slid from where it started.
    public var translation: Float { isValid ? b3PrismaticJoint_GetTranslation(id) : 0 }

    public var limits: ClosedRange<Float>? {
        didSet {
            guard isValid else { return }
            b3PrismaticJoint_EnableLimit(id, limits != nil)
            if let limits { b3PrismaticJoint_SetLimits(id, limits.lowerBound, limits.upperBound) }
        }
    }

    public var motor: JointMotor? {
        didSet {
            guard isValid else { return }
            b3PrismaticJoint_EnableMotor(id, motor != nil)
            if let motor {
                b3PrismaticJoint_SetMotorSpeed(id, motor.speed)
                b3PrismaticJoint_SetMaxMotorForce(id, motor.maximumForce)
            }
        }
    }
}

/// Bodies held at a shared point, free to turn every way: a shoulder, a pendulum.
public final class BallSocketJoint: PhysicsJoint {}

/// Bodies held a distance apart, rigidly or by a spring: a rope, a strut.
public final class DistanceJoint: PhysicsJoint {

    /// The distance it holds.
    public var length: Float {
        get { isValid ? b3DistanceJoint_GetLength(id) : 0 }
        set { if isValid { b3DistanceJoint_SetLength(id, newValue) } }
    }

    /// The anchors' distance now.
    public var currentLength: Float { isValid ? b3DistanceJoint_GetCurrentLength(id) : 0 }
}

/// Bodies held together as one.
public final class WeldJoint: PhysicsJoint {}

// MARK: - Making joints

public extension PhysicsWorld {

    /// A hinge: body A's `axisA` through `anchorA` and body B's `axisB` through `anchorB` are held together, and the
    /// bodies turn about it.
    @discardableResult
    func addHingeJoint(
        _ bodyA: PhysicsBody, anchor anchorA: SIMD3<Float>, axis axisA: SIMD3<Float>,
        _ bodyB: PhysicsBody, anchor anchorB: SIMD3<Float>, axis axisB: SIMD3<Float>,
        limits: ClosedRange<Float>? = nil, motor: JointMotor? = nil
    ) -> HingeJoint? {
        guard bodyA.isValid, bodyB.isValid else { return nil }
        var def = b3DefaultRevoluteJointDef()
        // Box3D's hinge turns about its frames' z axes.
        def.base = jointBase(bodyA, frame(anchorA, axisA, along: SIMD3(0, 0, 1)), bodyB, frame(anchorB, axisB, along: SIMD3(0, 0, 1)))
        if let limits {
            def.enableLimit = true
            def.lowerAngle = limits.lowerBound
            def.upperAngle = limits.upperBound
        }
        if let motor {
            def.enableMotor = true
            def.motorSpeed = motor.speed
            def.maxMotorTorque = motor.maximumForce
        }
        let joint = HingeJoint(world: self, id: b3CreateRevoluteJoint(id, &def), bodyA: bodyA, bodyB: bodyB)
        joint.limits = limits
        joint.motor = motor
        return register(joint)
    }

    /// A slider: the bodies keep their orientations and slide along body A's `axisA` through `anchorA`, held to body
    /// B's `axisB` through `anchorB`.
    @discardableResult
    func addSliderJoint(
        _ bodyA: PhysicsBody, anchor anchorA: SIMD3<Float>, axis axisA: SIMD3<Float>,
        _ bodyB: PhysicsBody, anchor anchorB: SIMD3<Float>, axis axisB: SIMD3<Float>,
        limits: ClosedRange<Float>? = nil, motor: JointMotor? = nil
    ) -> SliderJoint? {
        guard bodyA.isValid, bodyB.isValid else { return nil }
        var def = b3DefaultPrismaticJointDef()
        // Box3D's slider runs along frame A's x axis.
        def.base = jointBase(bodyA, frame(anchorA, axisA, along: SIMD3(1, 0, 0)), bodyB, frame(anchorB, axisB, along: SIMD3(1, 0, 0)))
        if let limits {
            def.enableLimit = true
            def.lowerTranslation = limits.lowerBound
            def.upperTranslation = limits.upperBound
        }
        if let motor {
            def.enableMotor = true
            def.motorSpeed = motor.speed
            def.maxMotorForce = motor.maximumForce
        }
        let joint = SliderJoint(world: self, id: b3CreatePrismaticJoint(id, &def), bodyA: bodyA, bodyB: bodyB)
        joint.limits = limits
        joint.motor = motor
        return register(joint)
    }

    /// A ball and socket: body A's `anchorA` and body B's `anchorB` are held together.
    @discardableResult
    func addBallSocketJoint(
        _ bodyA: PhysicsBody, anchor anchorA: SIMD3<Float>,
        _ bodyB: PhysicsBody, anchor anchorB: SIMD3<Float>
    ) -> BallSocketJoint? {
        guard bodyA.isValid, bodyB.isValid else { return nil }
        var def = b3DefaultSphericalJointDef()
        def.base = jointBase(bodyA, Transform(translation: anchorA), bodyB, Transform(translation: anchorB))
        return register(BallSocketJoint(world: self, id: b3CreateSphericalJoint(id, &def), bodyA: bodyA, bodyB: bodyB))
    }

    /// A distance joint: the anchors are held `length` apart (by default, as far as they are now). With a spring
    /// frequency, the length is a spring's rest length rather than rigid.
    @discardableResult
    func addDistanceJoint(
        _ bodyA: PhysicsBody, anchor anchorA: SIMD3<Float>,
        _ bodyB: PhysicsBody, anchor anchorB: SIMD3<Float>,
        length: Float? = nil, springFrequency: Float? = nil, dampingRatio: Float = 0.5
    ) -> DistanceJoint? {
        guard bodyA.isValid, bodyB.isValid else { return nil }
        var def = b3DefaultDistanceJointDef()
        def.base = jointBase(bodyA, Transform(translation: anchorA), bodyB, Transform(translation: anchorB))
        let worldA = bodyA.transform.matrix.transformPoint(anchorA), worldB = bodyB.transform.matrix.transformPoint(anchorB)
        def.length = length ?? (worldB - worldA).length
        if let springFrequency {
            def.enableSpring = true
            def.hertz = springFrequency
            def.dampingRatio = dampingRatio
        }
        return register(DistanceJoint(world: self, id: b3CreateDistanceJoint(id, &def), bodyA: bodyA, bodyB: bodyB))
    }

    /// A weld: the bodies are held as they are now, relative to each other.
    @discardableResult
    func addWeldJoint(_ bodyA: PhysicsBody, _ bodyB: PhysicsBody) -> WeldJoint? {
        guard bodyA.isValid, bodyB.isValid else { return nil }
        var def = b3DefaultWeldJointDef()
        // Frame A is body A's origin; frame B is the same place, in body B's space.
        let inB = Transform(matrix: (bodyB.transform.matrix.inverse ?? .identity) * bodyA.transform.matrix)
        def.base = jointBase(bodyA, .identity, bodyB, inB)
        return register(WeldJoint(world: self, id: b3CreateWeldJoint(id, &def), bodyA: bodyA, bodyB: bodyB))
    }

    /// Takes a joint out of the world.
    func remove(_ joint: PhysicsJoint) {
        guard joint.world === self else { return }
        unregister(joint)
        if b3Joint_IsValid(joint.id) { b3DestroyJoint(joint.id, true) }
        joint.invalidate()
    }

    // MARK: Helpers

    private func jointBase(_ bodyA: PhysicsBody, _ frameA: Transform, _ bodyB: PhysicsBody, _ frameB: Transform) -> b3JointDef {
        var base = b3DefaultRevoluteJointDef().base
        base.bodyIdA = bodyA.id
        base.bodyIdB = bodyB.id
        base.localFrameA = b3Transform(p: b3Vec3(frameA.translation), q: b3Quat(frameA.rotation))
        base.localFrameB = b3Transform(p: b3Vec3(frameB.translation), q: b3Quat(frameB.rotation))
        return base
    }

    /// A frame at `anchor` turned so its `along` axis points down `axis`.
    private func frame(_ anchor: SIMD3<Float>, _ axis: SIMD3<Float>, along: SIMD3<Float>) -> Transform {
        Transform(rotation: Quaternion(from: along, to: axis.lengthSquared > 0 ? axis : along), translation: anchor)
    }

    private func register<J: PhysicsJoint>(_ joint: J) -> J? {
        guard b3Joint_IsValid(joint.id) else { return nil }
        appendJoint(joint)
        return joint
    }
}
#endif
