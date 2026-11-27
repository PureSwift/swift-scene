/// A 4 by 4 matrix of floats, kept as columns, acting on column vectors: `a * b` applies `b` first.
/// The translation is the last column, as SceneKit, RealityKit, OpenGL and Metal expect.
///
/// QuickDraw 3D's `TQ3Matrix4x4` is the transpose: rows, acting on row vectors, the translation in the last row.
/// `init(rowMajor:)` and `rowMajorElements` convert between the two, and since a row-major matrix acting on
/// row vectors is the same transform as its transpose acting on column vectors, its sixteen floats read as
/// columns with `init(columnMajor:)` give the same transform here.
public struct Matrix4x4: Sendable {

    public var columns: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)

    @inlinable
    public init(_ c0: SIMD4<Float>, _ c1: SIMD4<Float>, _ c2: SIMD4<Float>, _ c3: SIMD4<Float>) {
        self.columns = (c0, c1, c2, c3)
    }

    @inlinable
    public init(columns: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)) {
        self.columns = columns
    }

    @inlinable
    public init(diagonal d: SIMD4<Float>) {
        self.init(SIMD4(d.x, 0, 0, 0), SIMD4(0, d.y, 0, 0), SIMD4(0, 0, d.z, 0), SIMD4(0, 0, 0, d.w))
    }

    public static let identity = Matrix4x4(diagonal: SIMD4(repeating: 1))

    /// Sixteen floats, a column at a time: the order of an `SCNMatrix4`'s or a GLKit matrix's members.
    public init<C: Collection>(columnMajor elements: C) where C.Element == Float {
        precondition(elements.count == 16, "A 4 by 4 matrix has sixteen elements")
        let a = Array(elements)
        self.init(SIMD4(a[0], a[1], a[2], a[3]), SIMD4(a[4], a[5], a[6], a[7]),
                  SIMD4(a[8], a[9], a[10], a[11]), SIMD4(a[12], a[13], a[14], a[15]))
    }

    /// Sixteen floats, a row at a time.
    public init<C: Collection>(rowMajor elements: C) where C.Element == Float {
        self = Matrix4x4(columnMajor: elements).transpose
    }

    public var columnMajorElements: [Float] {
        [columns.0.x, columns.0.y, columns.0.z, columns.0.w,
         columns.1.x, columns.1.y, columns.1.z, columns.1.w,
         columns.2.x, columns.2.y, columns.2.z, columns.2.w,
         columns.3.x, columns.3.y, columns.3.z, columns.3.w]
    }

    public var rowMajorElements: [Float] { transpose.columnMajorElements }

    /// A QuickDraw 3D matrix's sixteen floats (`TQ3Matrix4x4.value`, row by row, acting on row vectors)
    /// as the same transform acting on column vectors.
    public init<C: Collection>(quickDraw3D elements: C) where C.Element == Float {
        self.init(columnMajor: elements)
    }

    /// The transform as a QuickDraw 3D matrix's sixteen floats, row by row.
    public var quickDraw3DElements: [Float] { columnMajorElements }
}

// MARK: - Equatable, Hashable

extension Matrix4x4: Hashable {

    public static func == (lhs: Matrix4x4, rhs: Matrix4x4) -> Bool {
        lhs.columns.0 == rhs.columns.0 && lhs.columns.1 == rhs.columns.1
            && lhs.columns.2 == rhs.columns.2 && lhs.columns.3 == rhs.columns.3
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(columns.0)
        hasher.combine(columns.1)
        hasher.combine(columns.2)
        hasher.combine(columns.3)
    }
}

extension Matrix4x4: CustomStringConvertible {

    public var description: String {
        (0..<4).map { row in (0..<4).map { "\(self[row, $0])" }.joined(separator: " ") }.joined(separator: "\n")
    }
}

// MARK: - Elements

public extension Matrix4x4 {

    subscript(column: Int) -> SIMD4<Float> {
        get {
            switch column {
            case 0: columns.0
            case 1: columns.1
            case 2: columns.2
            case 3: columns.3
            default: preconditionFailure("Column \(column) out of range")
            }
        }
        set {
            switch column {
            case 0: columns.0 = newValue
            case 1: columns.1 = newValue
            case 2: columns.2 = newValue
            case 3: columns.3 = newValue
            default: preconditionFailure("Column \(column) out of range")
            }
        }
    }

    subscript(row: Int, column: Int) -> Float {
        get { self[column][row] }
        set { self[column][row] = newValue }
    }

    var transpose: Matrix4x4 {
        var result = Matrix4x4.identity
        for row in 0..<4 {
            for column in 0..<4 {
                result[column, row] = self[row, column]
            }
        }
        return result
    }

    /// The translation: the last column's x, y and z.
    var translation: SIMD3<Float> {
        get { columns.3.xyz }
        set { columns.3 = SIMD4(newValue, columns.3.w) }
    }
}

// MARK: - Arithmetic

public extension Matrix4x4 {

    static func * (lhs: Matrix4x4, rhs: SIMD4<Float>) -> SIMD4<Float> {
        lhs.columns.0 * rhs.x + lhs.columns.1 * rhs.y + lhs.columns.2 * rhs.z + lhs.columns.3 * rhs.w
    }

    static func * (lhs: Matrix4x4, rhs: Matrix4x4) -> Matrix4x4 {
        Matrix4x4(lhs * rhs.columns.0, lhs * rhs.columns.1, lhs * rhs.columns.2, lhs * rhs.columns.3)
    }

    static func *= (lhs: inout Matrix4x4, rhs: Matrix4x4) {
        lhs = lhs * rhs
    }

    /// A point moved by the matrix, with no perspective divide.
    func transformPoint(_ p: SIMD3<Float>) -> SIMD3<Float> {
        (self * SIMD4(p, 1)).xyz
    }

    /// A point moved by the matrix and divided by its w, as a projection takes it to normalized device coordinates.
    func projectPoint(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let h = self * SIMD4(p, 1)
        return h.w != 0 ? h.xyz / h.w : h.xyz
    }

    /// A direction turned and scaled by the matrix, not moved.
    func transformDirection(_ v: SIMD3<Float>) -> SIMD3<Float> {
        (self * SIMD4(v, 0)).xyz
    }

    var determinant: Float {
        let m = columnMajorElements
        let c = Matrix4x4.cofactors(m)
        return m[0] * c[0] + m[1] * c[4] + m[2] * c[8] + m[3] * c[12]
    }

    /// The inverse, or nil when the matrix is singular.
    var inverse: Matrix4x4? {
        let m = columnMajorElements
        let c = Matrix4x4.cofactors(m)
        let det = m[0] * c[0] + m[1] * c[4] + m[2] * c[8] + m[3] * c[12]
        guard det != 0, det.isFinite else { return nil }
        return Matrix4x4(columnMajor: c.map { $0 / det })
    }

    /// The inverse transpose of the upper left 3 by 3, for turning normals; the rest is the identity's.
    var normalMatrix: Matrix4x4 {
        var upper = self
        upper.columns.0.w = 0
        upper.columns.1.w = 0
        upper.columns.2.w = 0
        upper.columns.3 = SIMD4(0, 0, 0, 1)
        return upper.inverse?.transpose ?? .identity
    }

    /// The adjugate's elements: the inverse times the determinant. The layout is the input's, whichever it is,
    /// since the inverse of a transpose is the transpose of the inverse.
    private static func cofactors(_ m: [Float]) -> [Float] {
        var inv = [Float](repeating: 0, count: 16)
        inv[0] = m[5] * m[10] * m[15] - m[5] * m[11] * m[14] - m[9] * m[6] * m[15] + m[9] * m[7] * m[14] + m[13] * m[6] * m[11] - m[13] * m[7] * m[10]
        inv[4] = -m[4] * m[10] * m[15] + m[4] * m[11] * m[14] + m[8] * m[6] * m[15] - m[8] * m[7] * m[14] - m[12] * m[6] * m[11] + m[12] * m[7] * m[10]
        inv[8] = m[4] * m[9] * m[15] - m[4] * m[11] * m[13] - m[8] * m[5] * m[15] + m[8] * m[7] * m[13] + m[12] * m[5] * m[11] - m[12] * m[7] * m[9]
        inv[12] = -m[4] * m[9] * m[14] + m[4] * m[10] * m[13] + m[8] * m[5] * m[14] - m[8] * m[6] * m[13] - m[12] * m[5] * m[10] + m[12] * m[6] * m[9]
        inv[1] = -m[1] * m[10] * m[15] + m[1] * m[11] * m[14] + m[9] * m[2] * m[15] - m[9] * m[3] * m[14] - m[13] * m[2] * m[11] + m[13] * m[3] * m[10]
        inv[5] = m[0] * m[10] * m[15] - m[0] * m[11] * m[14] - m[8] * m[2] * m[15] + m[8] * m[3] * m[14] + m[12] * m[2] * m[11] - m[12] * m[3] * m[10]
        inv[9] = -m[0] * m[9] * m[15] + m[0] * m[11] * m[13] + m[8] * m[1] * m[15] - m[8] * m[3] * m[13] - m[12] * m[1] * m[11] + m[12] * m[3] * m[9]
        inv[13] = m[0] * m[9] * m[14] - m[0] * m[10] * m[13] - m[8] * m[1] * m[14] + m[8] * m[2] * m[13] + m[12] * m[1] * m[10] - m[12] * m[2] * m[9]
        inv[2] = m[1] * m[6] * m[15] - m[1] * m[7] * m[14] - m[5] * m[2] * m[15] + m[5] * m[3] * m[14] + m[13] * m[2] * m[7] - m[13] * m[3] * m[6]
        inv[6] = -m[0] * m[6] * m[15] + m[0] * m[7] * m[14] + m[4] * m[2] * m[15] - m[4] * m[3] * m[14] - m[12] * m[2] * m[7] + m[12] * m[3] * m[6]
        inv[10] = m[0] * m[5] * m[15] - m[0] * m[7] * m[13] - m[4] * m[1] * m[15] + m[4] * m[3] * m[13] + m[12] * m[1] * m[7] - m[12] * m[3] * m[5]
        inv[14] = -m[0] * m[5] * m[14] + m[0] * m[6] * m[13] + m[4] * m[1] * m[14] - m[4] * m[2] * m[13] - m[12] * m[1] * m[6] + m[12] * m[2] * m[5]
        inv[3] = -m[1] * m[6] * m[11] + m[1] * m[7] * m[10] + m[5] * m[2] * m[11] - m[5] * m[3] * m[10] - m[9] * m[2] * m[7] + m[9] * m[3] * m[6]
        inv[7] = m[0] * m[6] * m[11] - m[0] * m[7] * m[10] - m[4] * m[2] * m[11] + m[4] * m[3] * m[10] + m[8] * m[2] * m[7] - m[8] * m[3] * m[6]
        inv[11] = -m[0] * m[5] * m[11] + m[0] * m[7] * m[9] + m[4] * m[1] * m[11] - m[4] * m[3] * m[9] - m[8] * m[1] * m[7] + m[8] * m[3] * m[5]
        inv[15] = m[0] * m[5] * m[10] - m[0] * m[6] * m[9] - m[4] * m[1] * m[10] + m[4] * m[2] * m[9] + m[8] * m[1] * m[6] - m[8] * m[2] * m[5]
        return inv
    }
}

// MARK: - Transforms

public extension Matrix4x4 {

    init(translation t: SIMD3<Float>) {
        self = .identity
        columns.3 = SIMD4(t, 1)
    }

    init(scale s: SIMD3<Float>) {
        self.init(diagonal: SIMD4(s, 1))
    }

    init(rotation q: Quaternion) {
        let q = q.normalized
        let x = q.vector.x, y = q.vector.y, z = q.vector.z, w = q.vector.w
        self.init(
            SIMD4(1 - 2 * (y * y + z * z), 2 * (x * y + z * w), 2 * (x * z - y * w), 0),
            SIMD4(2 * (x * y - z * w), 1 - 2 * (x * x + z * z), 2 * (y * z + x * w), 0),
            SIMD4(2 * (x * z + y * w), 2 * (y * z - x * w), 1 - 2 * (x * x + y * y), 0),
            SIMD4(0, 0, 0, 1)
        )
    }

    /// A perspective projection to OpenGL's clip space (z from -1 to 1), with a vertical field of view in radians.
    static func perspective(verticalFieldOfView fovy: Float, aspectRatio aspect: Float, near: Float, far: Float) -> Matrix4x4 {
        let f = 1 / Elementary.tan(fovy / 2)
        var m = Matrix4x4(diagonal: .zero)
        m[0, 0] = f / aspect
        m[1, 1] = f
        m[2, 2] = far == .infinity ? -1 : (far + near) / (near - far)
        m[3, 2] = -1
        m[2, 3] = far == .infinity ? -2 * near : 2 * far * near / (near - far)
        return m
    }

    /// An orthographic projection to OpenGL's clip space.
    static func orthographic(left: Float, right: Float, bottom: Float, top: Float, near: Float, far: Float) -> Matrix4x4 {
        var m = Matrix4x4.identity
        m[0, 0] = 2 / (right - left)
        m[1, 1] = 2 / (top - bottom)
        m[2, 2] = -2 / (far - near)
        m[0, 3] = -(right + left) / (right - left)
        m[1, 3] = -(top + bottom) / (top - bottom)
        m[2, 3] = -(far + near) / (far - near)
        return m
    }

    /// The view matrix of an eye at `eye` looking at `target`, `up` as near up as it can be.
    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> Matrix4x4 {
        let f = (target - eye).normalized
        var s = f.cross(up).normalized
        if s.lengthSquared == 0 { s = f.cross(SIMD3(0, 0, 1)).normalized }
        let u = s.cross(f)
        return Matrix4x4(
            SIMD4(s.x, u.x, -f.x, 0),
            SIMD4(s.y, u.y, -f.y, 0),
            SIMD4(s.z, u.z, -f.z, 0),
            SIMD4(-s.dot(eye), -u.dot(eye), f.dot(eye), 1)
        )
    }
}

// MARK: - simd

#if canImport(simd)
import simd

public extension Matrix4x4 {

    @inlinable
    init(_ matrix: simd_float4x4) {
        self.init(matrix.columns.0, matrix.columns.1, matrix.columns.2, matrix.columns.3)
    }
}

public extension simd_float4x4 {

    @inlinable
    init(_ matrix: Matrix4x4) {
        self.init(matrix.columns.0, matrix.columns.1, matrix.columns.2, matrix.columns.3)
    }
}
#endif
