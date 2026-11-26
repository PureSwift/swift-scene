#if canImport(CBox3D)
import CBox3D
import SceneCore

/// How a surface slides, bounces and weighs.
public struct PhysicsMaterial: Hashable, Sendable {
    /// Coulomb friction, usually 0 to 1.
    public var friction: Float
    /// Bounciness: 0 for none, 1 for a perfect bounce.
    public var restitution: Float
    /// Mass per cubic unit, for a dynamic body's mass.
    public var density: Float
    public var rollingResistance: Float

    public init(friction: Float = 0.6, restitution: Float = 0, density: Float = 1, rollingResistance: Float = 0) {
        self.friction = friction
        self.restitution = restitution
        self.density = density
        self.rollingResistance = rollingResistance
    }
}

/// One of a body's collision shapes, in the body's space.
public final class PhysicsShape {

    /// What a shape is.
    public enum Geometry: Hashable, Sendable {
        case sphere(radius: Float, center: SIMD3<Float> = .zero)
        /// A cylinder with round ends between two points.
        case capsule(SIMD3<Float>, SIMD3<Float>, radius: Float)
        case box(halfExtents: SIMD3<Float>, center: SIMD3<Float> = .zero, orientation: Quaternion = .identity)
        /// The smallest convex shape around the points.
        case convexHull([SIMD3<Float>])
        /// A mesh's triangles, as they are: for static bodies.
        case triangleMesh(MeshBuffer)
    }

    public let geometry: Geometry

    public private(set) weak var body: PhysicsBody?

    private(set) var id: b3ShapeId

    /// Mesh data Box3D references rather than copies, kept while the shape is.
    private let meshData: MeshData?

    init?(body: PhysicsBody, geometry: Geometry, material: PhysicsMaterial) {
        var def = b3DefaultShapeDef()
        def.density = material.density
        def.baseMaterial.friction = material.friction
        def.baseMaterial.restitution = material.restitution
        def.baseMaterial.rollingResistance = material.rollingResistance
        def.enableContactEvents = true
        let bodyId = body.id
        var meshData: MeshData?
        let id: b3ShapeId
        switch geometry {
        case let .sphere(radius, center):
            var sphere = b3Sphere(center: b3Vec3(center), radius: radius)
            id = b3CreateSphereShape(bodyId, &def, &sphere)
        case let .capsule(a, b, radius):
            var capsule = b3Capsule(center1: b3Vec3(a), center2: b3Vec3(b), radius: radius)
            id = b3CreateCapsuleShape(bodyId, &def, &capsule)
        case let .box(halfExtents, center, orientation):
            // Box3D copies a hull into its world, so one on the stack will do.
            var hull = b3MakeTransformedBoxHull(halfExtents.x, halfExtents.y, halfExtents.z,
                                                b3Transform(p: b3Vec3(center), q: b3Quat(orientation)))
            id = withUnsafePointer(to: &hull.base) { b3CreateHullShape(bodyId, &def, $0) }
        case let .convexHull(points):
            let vertices = points.map(b3Vec3.init)
            guard let hull = vertices.withUnsafeBufferPointer({ b3CreateHull($0.baseAddress, Int32($0.count), Int32(min(points.count, 255))) }) else {
                return nil
            }
            defer { b3DestroyHull(hull) }
            id = b3CreateHullShape(bodyId, &def, hull)
        case let .triangleMesh(mesh):
            guard let data = MeshData(mesh) else { return nil }
            meshData = data
            id = b3CreateMeshShape(bodyId, &def, data.pointer, b3Vec3(x: 1, y: 1, z: 1))
        }
        guard b3Shape_IsValid(id) else { return nil }
        self.id = id
        self.geometry = geometry
        self.body = body
        self.meshData = meshData
    }

    func destroy() {
        if b3Shape_IsValid(id) { b3DestroyShape(id, true) }
        id = b3_nullShapeId
        body = nil
    }

    public var friction: Float {
        get { b3Shape_IsValid(id) ? b3Shape_GetFriction(id) : 0 }
        set { if b3Shape_IsValid(id) { b3Shape_SetFriction(id, newValue) } }
    }

    public var restitution: Float {
        get { b3Shape_IsValid(id) ? b3Shape_GetRestitution(id) : 0 }
        set { if b3Shape_IsValid(id) { b3Shape_SetRestitution(id, newValue) } }
    }

    public var density: Float {
        get { b3Shape_IsValid(id) ? b3Shape_GetDensity(id) : 0 }
        set { if b3Shape_IsValid(id) { b3Shape_SetDensity(id, newValue, true) } }
    }
}

/// A triangle mesh in Box3D's form, freed with the last shape that holds it.
final class MeshData {

    let pointer: UnsafeMutablePointer<b3MeshData>

    init?(_ mesh: MeshBuffer) {
        var positions = mesh.positions.map(b3Vec3.init)
        var indices: [Int32] = []
        for submesh in mesh.submeshes {
            for t in mesh.triangles(in: submesh) { indices += [Int32(t.x), Int32(t.y), Int32(t.z)] }
        }
        guard !positions.isEmpty, !indices.isEmpty else { return nil }
        // Box3D copies what it needs out of the definition.
        let triangleCount = indices.count / 3
        let made: UnsafeMutablePointer<b3MeshData>? = positions.withUnsafeMutableBufferPointer { points in
            indices.withUnsafeMutableBufferPointer { triangles in
                var def = b3MeshDef()
                def.vertices = points.baseAddress
                def.vertexCount = Int32(points.count)
                def.indices = triangles.baseAddress
                def.triangleCount = Int32(triangleCount)
                return b3CreateMesh(&def, nil, 0)
            }
        }
        guard let made else { return nil }
        pointer = made
    }

    deinit {
        b3DestroyMesh(pointer)
    }
}
#endif
