/// A translation, rotation and scale, applied scale first, then rotation, then translation.
public struct Transform: Hashable, Sendable {

    public var scale: SIMD3<Float>

    public var rotation: Quaternion

    public var translation: SIMD3<Float>

    public init(
        scale: SIMD3<Float> = SIMD3(repeating: 1),
        rotation: Quaternion = .identity,
        translation: SIMD3<Float> = .zero
    ) {
        self.scale = scale
        self.rotation = rotation
        self.translation = translation
    }

    public static let identity = Transform()

    /// A matrix as a translation, rotation and scale; the scale is the lengths of the columns,
    /// so shear and reflection are not kept.
    public init(matrix m: Matrix4x4) {
        let columns = [m.columns.0.xyz, m.columns.1.xyz, m.columns.2.xyz]
        let scale = SIMD3(columns[0].length, columns[1].length, columns[2].length)
        var r = Matrix4x4.identity
        for c in 0..<3 where scale[c] > 0 {
            r[c] = SIMD4(columns[c] / scale[c], 0)
        }
        self.init(scale: scale, rotation: Quaternion(rotationMatrix: r), translation: m.translation)
    }

    /// The transform as a matrix: T * R * S.
    public var matrix: Matrix4x4 {
        var m = Matrix4x4(rotation: rotation)
        m.columns.0 *= scale.x
        m.columns.1 *= scale.y
        m.columns.2 *= scale.z
        m.columns.3 = SIMD4(translation, 1)
        return m
    }
}
