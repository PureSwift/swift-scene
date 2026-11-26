#if canImport(CBox3D)
import CBox3D
import SceneCore

// Box3D's vectors and quaternions as SceneCore's. Box3D is built in single precision, so its positions (`b3Pos`)
// are vectors too.

extension b3Vec3 {
    init(_ v: SIMD3<Float>) {
        self.init(x: v.x, y: v.y, z: v.z)
    }
}

extension SIMD3 where Scalar == Float {
    init(_ v: b3Vec3) {
        self.init(v.x, v.y, v.z)
    }
}

extension b3Quat {
    init(_ q: Quaternion) {
        self.init(v: b3Vec3(q.imag), s: q.real)
    }
}

extension Quaternion {
    init(_ q: b3Quat) {
        self.init(real: q.s, imag: SIMD3(q.v))
    }
}
#endif
