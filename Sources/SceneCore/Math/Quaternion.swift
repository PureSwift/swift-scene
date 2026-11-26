/// A rotation, as a unit quaternion: the imaginary part in `x`, `y`, `z` and the real part in `w`,
/// the same layout as `simd_quatf`.
public struct Quaternion: Hashable, Sendable {

    public var vector: SIMD4<Float>

    @inlinable
    public init(vector: SIMD4<Float>) {
        self.vector = vector
    }

    @inlinable
    public init(ix: Float, iy: Float, iz: Float, r: Float) {
        self.vector = SIMD4(ix, iy, iz, r)
    }

    @inlinable
    public init(real: Float, imag: SIMD3<Float>) {
        self.vector = SIMD4(imag, real)
    }

    /// No rotation.
    public static let identity = Quaternion(vector: SIMD4(0, 0, 0, 1))

    @inlinable
    public var real: Float {
        get { vector.w }
        set { vector.w = newValue }
    }

    @inlinable
    public var imag: SIMD3<Float> {
        get { vector.xyz }
        set { vector = SIMD4(newValue, vector.w) }
    }
}

// MARK: - Construction

public extension Quaternion {

    /// A turn of `angle` radians about `axis`, counter-clockwise looking down the axis; no rotation for a zero axis.
    init(angle: Float, axis: SIMD3<Float>) {
        let length = axis.length
        guard length > 0 else {
            self = .identity
            return
        }
        let s = Elementary.sin(angle / 2) / length
        self.init(real: Elementary.cos(angle / 2), imag: axis * s)
    }

    /// Pitch, yaw and roll as SceneKit applies them: about z first, then y, then x.
    init(eulerAngles e: SIMD3<Float>) {
        let x = Quaternion(angle: e.x, axis: SIMD3(1, 0, 0))
        let y = Quaternion(angle: e.y, axis: SIMD3(0, 1, 0))
        let z = Quaternion(angle: e.z, axis: SIMD3(0, 0, 1))
        self = x * y * z
    }

    /// The rotation of a matrix's upper left 3 by 3, which must be orthonormal.
    init(rotationMatrix m: Matrix4x4) {
        // m(r, c) is the entry at row r, column c.
        func m_(_ r: Int, _ c: Int) -> Float { m[r, c] }
        let trace = m_(0, 0) + m_(1, 1) + m_(2, 2)
        if trace > 0 {
            let s = (trace + 1).squareRoot() * 2
            self.init(ix: (m_(2, 1) - m_(1, 2)) / s, iy: (m_(0, 2) - m_(2, 0)) / s, iz: (m_(1, 0) - m_(0, 1)) / s, r: s / 4)
        } else if m_(0, 0) > m_(1, 1), m_(0, 0) > m_(2, 2) {
            let s = (1 + m_(0, 0) - m_(1, 1) - m_(2, 2)).squareRoot() * 2
            self.init(ix: s / 4, iy: (m_(0, 1) + m_(1, 0)) / s, iz: (m_(0, 2) + m_(2, 0)) / s, r: (m_(2, 1) - m_(1, 2)) / s)
        } else if m_(1, 1) > m_(2, 2) {
            let s = (1 + m_(1, 1) - m_(0, 0) - m_(2, 2)).squareRoot() * 2
            self.init(ix: (m_(0, 1) + m_(1, 0)) / s, iy: s / 4, iz: (m_(1, 2) + m_(2, 1)) / s, r: (m_(0, 2) - m_(2, 0)) / s)
        } else {
            let s = (1 + m_(2, 2) - m_(0, 0) - m_(1, 1)).squareRoot() * 2
            self.init(ix: (m_(0, 2) + m_(2, 0)) / s, iy: (m_(1, 2) + m_(2, 1)) / s, iz: s / 4, r: (m_(1, 0) - m_(0, 1)) / s)
        }
        self = normalized
    }

    /// The shortest rotation taking the direction `from` to the direction `to`.
    init(from: SIMD3<Float>, to: SIMD3<Float>) {
        let a = from.normalized, b = to.normalized
        let d = a.dot(b)
        if d >= 1 - 1e-6 {
            self = .identity
        } else if d <= -1 + 1e-6 {
            // Opposite: half a turn about any perpendicular.
            var axis = SIMD3<Float>(1, 0, 0).cross(a)
            if axis.lengthSquared < 1e-6 { axis = SIMD3<Float>(0, 1, 0).cross(a) }
            self.init(angle: .pi, axis: axis)
        } else {
            self = Quaternion(real: 1 + d, imag: a.cross(b)).normalized
        }
    }
}

// MARK: - Properties

public extension Quaternion {

    @inlinable
    var length: Float { vector.dot(vector).squareRoot() }

    /// The quaternion at unit length; no rotation for zero.
    var normalized: Quaternion {
        let length = self.length
        return length > 0 ? Quaternion(vector: vector / length) : .identity
    }

    @inlinable
    var conjugate: Quaternion { Quaternion(real: real, imag: -imag) }

    var inverse: Quaternion {
        let lengthSquared = vector.dot(vector)
        return lengthSquared > 0 ? Quaternion(vector: conjugate.vector / lengthSquared) : .identity
    }

    /// The angle turned, in radians, from 0 to 2π.
    var angle: Float {
        2 * Elementary.acos(min(max(normalized.real, -1), 1))
    }

    /// The axis turned about; y for no rotation.
    var axis: SIMD3<Float> {
        let q = normalized
        let s = (1 - q.real * q.real).squareRoot()
        guard s > 1e-6 else { return SIMD3(0, 1, 0) }
        return q.imag / s
    }

    /// The rotation as Euler angles, in SceneKit's order (see `init(eulerAngles:)`).
    var eulerAngles: SIMD3<Float> { eulerAngles(sceneKitReadBack: false) }

    /// The rotation as Euler angles. With `sceneKitReadBack`, a quarter turn about y exactly reads back
    /// turned the other way, as a SceneKit node's `eulerAngles` does: games tell which way a thing faces by that sign.
    func eulerAngles(sceneKitReadBack: Bool) -> SIMD3<Float> {
        // The matrix is Rx * Ry * Rz.
        let m = Matrix4x4(rotation: self)
        let sine = min(max(m[0, 2], -1), 1)
        let yaw = Elementary.asin(sine)
        if abs(sine) < 0.99999 {
            return SIMD3(Elementary.atan2(-m[1, 2], m[2, 2]), yaw, Elementary.atan2(-m[0, 1], m[0, 0]))
        }
        if sceneKitReadBack, abs(sine) >= 0.9999999, abs(m[1, 1] - 1) < 1e-6 {
            return SIMD3(0, -yaw, 0)
        }
        return SIMD3(Elementary.atan2(m[2, 1], m[1, 1]), yaw, 0)
    }
}

// MARK: - Operations

public extension Quaternion {

    /// The Hamilton product: `rhs` applied first, then `lhs`.
    static func * (lhs: Quaternion, rhs: Quaternion) -> Quaternion {
        let a = lhs.vector, b = rhs.vector
        return Quaternion(
            ix: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            iy: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            iz: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
            r: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z
        )
    }

    static func *= (lhs: inout Quaternion, rhs: Quaternion) {
        lhs = lhs * rhs
    }

    /// A vector rotated.
    func act(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let u = imag, s = real
        return 2 * u.dot(v) * u + (s * s - u.dot(u)) * v + 2 * s * u.cross(v)
    }

    /// The rotation `t` of the way from `from` to `to`, the short way round.
    static func slerp(from a: Quaternion, to b: Quaternion, t: Float) -> Quaternion {
        var b = b.vector
        var d = a.vector.dot(b)
        if d < 0 {
            b = -b
            d = -d
        }
        if d > 0.9995 {
            return Quaternion(vector: a.vector + (b - a.vector) * t).normalized
        }
        let theta = Elementary.acos(min(d, 1)), s = Elementary.sin(theta)
        let wa = Elementary.sin((1 - t) * theta) / s, wb = Elementary.sin(t * theta) / s
        return Quaternion(vector: a.vector * wa + b * wb).normalized
    }
}

// MARK: - simd

#if canImport(simd)
import simd

public extension Quaternion {

    @inlinable
    init(_ quaternion: simd_quatf) {
        self.init(vector: quaternion.vector)
    }
}

public extension simd_quatf {

    @inlinable
    init(_ quaternion: Quaternion) {
        self.init(vector: quaternion.vector)
    }
}
#endif
