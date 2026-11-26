/// An axis-aligned bounding box.
public struct BoundingBox: Hashable, Sendable {

    public var min: SIMD3<Float>

    public var max: SIMD3<Float>

    @inlinable
    public init(min: SIMD3<Float>, max: SIMD3<Float>) {
        self.min = min
        self.max = max
    }

    /// The box around nothing, which any point's union replaces.
    public static let empty = BoundingBox(min: SIMD3(repeating: .infinity), max: SIMD3(repeating: -.infinity))

    /// The box around the points; empty for none.
    public init<S: Sequence>(points: S) where S.Element == SIMD3<Float> {
        self = .empty
        for point in points { formUnion(point) }
    }

    public var isEmpty: Bool { any(min .> max) }

    public var center: SIMD3<Float> { (min + max) / 2 }

    /// The size along each axis.
    public var extents: SIMD3<Float> { isEmpty ? .zero : max - min }

    public var halfExtents: SIMD3<Float> { extents / 2 }

    /// The eight corners.
    public var corners: [SIMD3<Float>] {
        (0..<8).map { i in
            SIMD3(i & 1 == 0 ? min.x : max.x, i & 2 == 0 ? min.y : max.y, i & 4 == 0 ? min.z : max.z)
        }
    }

    public mutating func formUnion(_ point: SIMD3<Float>) {
        min = pointwiseMin(min, point)
        max = pointwiseMax(max, point)
    }

    public mutating func formUnion(_ other: BoundingBox) {
        guard !other.isEmpty else { return }
        min = pointwiseMin(min, other.min)
        max = pointwiseMax(max, other.max)
    }

    public func union(_ other: BoundingBox) -> BoundingBox {
        var box = self
        box.formUnion(other)
        return box
    }

    public func contains(_ point: SIMD3<Float>) -> Bool {
        all(point .>= min) && all(point .<= max)
    }

    public func intersects(_ other: BoundingBox) -> Bool {
        !isEmpty && !other.isEmpty && all(min .<= other.max) && all(max .>= other.min)
    }

    /// The box around this one moved by a matrix (Arvo's method).
    public func transformed(by m: Matrix4x4) -> BoundingBox {
        guard !isEmpty else { return self }
        var result = BoundingBox(min: m.translation, max: m.translation)
        for column in 0..<3 {
            let axis = m[column].xyz
            let a = axis * min[column], b = axis * max[column]
            result.min += pointwiseMin(a, b)
            result.max += pointwiseMax(a, b)
        }
        return result
    }

    /// The smallest sphere around the box.
    public var boundingSphere: BoundingSphere {
        isEmpty ? BoundingSphere(center: .zero, radius: 0) : BoundingSphere(center: center, radius: halfExtents.length)
    }
}

/// A sphere, for quick culling.
public struct BoundingSphere: Hashable, Sendable {

    public var center: SIMD3<Float>

    public var radius: Float

    @inlinable
    public init(center: SIMD3<Float>, radius: Float) {
        self.center = center
        self.radius = radius
    }

    public func contains(_ point: SIMD3<Float>) -> Bool {
        (point - center).lengthSquared <= radius * radius
    }

    public func intersects(_ other: BoundingSphere) -> Bool {
        let reach = radius + other.radius
        return (other.center - center).lengthSquared <= reach * reach
    }

    /// The sphere moved by a matrix; a non-uniform scale grows it by the largest axis's.
    public func transformed(by m: Matrix4x4) -> BoundingSphere {
        let scale = Swift.max(m.columns.0.xyz.length, m.columns.1.xyz.length, m.columns.2.xyz.length)
        return BoundingSphere(center: m.transformPoint(center), radius: radius * scale)
    }
}

/// A plane: the points `p` where `normal · p + distance` is zero; the normal's side is in front.
public struct Plane: Hashable, Sendable {

    public var normal: SIMD3<Float>

    public var distance: Float

    @inlinable
    public init(normal: SIMD3<Float>, distance: Float) {
        self.normal = normal
        self.distance = distance
    }

    public init(normal: SIMD3<Float>, point: SIMD3<Float>) {
        let n = normal.normalized
        self.init(normal: n, distance: -n.dot(point))
    }

    /// From a plane's equation as four coefficients, scaled so the normal has unit length.
    public init(coefficients c: SIMD4<Float>) {
        let length = c.xyz.length
        self.init(normal: length > 0 ? c.xyz / length : c.xyz, distance: length > 0 ? c.w / length : c.w)
    }

    /// How far the point is in front of the plane; negative behind.
    public func signedDistance(to point: SIMD3<Float>) -> Float {
        normal.dot(point) + distance
    }
}

/// A ray: a start and a direction.
public struct Ray: Hashable, Sendable {

    public var origin: SIMD3<Float>

    public var direction: SIMD3<Float>

    @inlinable
    public init(origin: SIMD3<Float>, direction: SIMD3<Float>) {
        self.origin = origin
        self.direction = direction
    }

    /// The point `t` directions along.
    public func point(at t: Float) -> SIMD3<Float> { origin + direction * t }

    /// The ray moved by a matrix; the direction is not normalized, so distances along it are kept.
    public func transformed(by m: Matrix4x4) -> Ray {
        Ray(origin: m.transformPoint(origin), direction: m.transformDirection(direction))
    }

    /// Where the ray first enters the box, if it does (the slab method); 0 when it starts inside.
    public func intersection(with box: BoundingBox) -> Float? {
        guard !box.isEmpty else { return nil }
        var near: Float = 0, far = Float.infinity
        for axis in 0..<3 {
            let d = direction[axis], o = origin[axis]
            if abs(d) < .ulpOfOne {
                if o < box.min[axis] || o > box.max[axis] { return nil }
                continue
            }
            var t0 = (box.min[axis] - o) / d, t1 = (box.max[axis] - o) / d
            if t0 > t1 { swap(&t0, &t1) }
            near = Swift.max(near, t0)
            far = Swift.min(far, t1)
            if near > far { return nil }
        }
        return near
    }

    /// Where the ray first meets the sphere, if it does; 0 when it starts inside.
    public func intersection(with sphere: BoundingSphere) -> Float? {
        let oc = origin - sphere.center
        let a = direction.lengthSquared
        guard a > 0 else { return nil }
        let b = oc.dot(direction)
        let c = oc.lengthSquared - sphere.radius * sphere.radius
        let discriminant = b * b - a * c
        guard discriminant >= 0 else { return nil }
        let root = discriminant.squareRoot()
        let t0 = (-b - root) / a, t1 = (-b + root) / a
        if t1 < 0 { return nil }
        return Swift.max(t0, 0)
    }

    /// Where the ray meets a triangle from either side, and the barycentric coordinates of `b` and `c` there
    /// (Möller and Trumbore's method).
    public func intersection(
        withTriangle a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>
    ) -> (distance: Float, barycentric: SIMD2<Float>)? {
        let e1 = b - a, e2 = c - a
        let p = direction.cross(e2)
        let det = e1.dot(p)
        guard abs(det) > 1e-8 else { return nil }
        let inverse = 1 / det
        let s = origin - a
        let u = s.dot(p) * inverse
        guard u >= 0, u <= 1 else { return nil }
        let q = s.cross(e1)
        let v = direction.dot(q) * inverse
        guard v >= 0, u + v <= 1 else { return nil }
        let t = e2.dot(q) * inverse
        guard t >= 0 else { return nil }
        return (t, SIMD2(u, v))
    }
}

/// The six planes bounding what a camera sees, facing in.
public struct Frustum: Hashable, Sendable {

    /// Left, right, bottom, top, near and far.
    public var planes: [Plane]

    public init(planes: [Plane]) {
        precondition(planes.count == 6, "A frustum has six planes")
        self.planes = planes
    }

    /// The frustum of a projection times a view, for OpenGL's clip space (Gribb and Hartmann's method).
    public init(viewProjection m: Matrix4x4) {
        // The rows of the matrix.
        let r = (0..<4).map { row in SIMD4(m[row, 0], m[row, 1], m[row, 2], m[row, 3]) }
        self.init(planes: [
            Plane(coefficients: r[3] + r[0]),
            Plane(coefficients: r[3] - r[0]),
            Plane(coefficients: r[3] + r[1]),
            Plane(coefficients: r[3] - r[1]),
            Plane(coefficients: r[3] + r[2]),
            Plane(coefficients: r[3] - r[2]),
        ])
    }

    public func contains(_ point: SIMD3<Float>) -> Bool {
        planes.allSatisfy { $0.signedDistance(to: point) >= 0 }
    }

    /// Whether the sphere is at least partly inside.
    public func intersects(_ sphere: BoundingSphere) -> Bool {
        planes.allSatisfy { $0.signedDistance(to: sphere.center) >= -sphere.radius }
    }

    /// Whether the box may be at least partly inside: false only when it is wholly behind one plane.
    public func intersects(_ box: BoundingBox) -> Bool {
        guard !box.isEmpty else { return false }
        for plane in planes {
            // The corner furthest along the plane's normal.
            let positive = SIMD3(
                plane.normal.x >= 0 ? box.max.x : box.min.x,
                plane.normal.y >= 0 ? box.max.y : box.min.y,
                plane.normal.z >= 0 ? box.max.z : box.min.z
            )
            if plane.signedDistance(to: positive) < 0 { return false }
        }
        return true
    }
}
