/// Cuts polygons into triangles: concave ones, and ones with holes.
///
/// Contours combine by the even-odd rule: a contour inside an odd number of others is a hole in the innermost
/// one around it, and one inside an even number is an island. Each outer contour has its holes bridged into it,
/// and the simple polygon that leaves is cut by ear clipping. Contours that cross one another are each filled on
/// their own, a union rather than the even-odd rule's exclusive or.
public enum Triangulation {

    /// Triangles over contours in 3D, as indices into the contours' points taken in order, one contour after
    /// another, wound counter-clockwise about `normal` (by default the first contour's own normal). The points
    /// are projected onto the plane the normal is most nearly perpendicular to.
    public static func triangulate(_ contours: [[SIMD3<Float>]], normal: SIMD3<Float>? = nil) -> [SIMD3<Int>] {
        guard let first = contours.first(where: { $0.count >= 3 }) else { return [] }
        let n = normal ?? newellNormal(first)
        guard n.lengthSquared > 0 else { return [] }
        // Drop the axis the normal is largest along, keeping the remaining two right-handed about it.
        let a = abs(n)
        let flat: [[SIMD2<Float>]]
        if a.z >= a.x, a.z >= a.y {
            flat = contours.map { $0.map { n.z >= 0 ? SIMD2($0.x, $0.y) : SIMD2($0.y, $0.x) } }
        } else if a.x >= a.y {
            flat = contours.map { $0.map { n.x >= 0 ? SIMD2($0.y, $0.z) : SIMD2($0.z, $0.y) } }
        } else {
            flat = contours.map { $0.map { n.y >= 0 ? SIMD2($0.z, $0.x) : SIMD2($0.x, $0.z) } }
        }
        return triangulate(flat)
    }

    /// Triangles over contours in the plane, counter-clockwise, as indices into the contours' points in order.
    public static func triangulate(_ contours: [[SIMD2<Float>]]) -> [SIMD3<Int>] {
        // Each contour's points, by their indices in the whole.
        var offsets: [Int] = []
        var total = 0
        for contour in contours {
            offsets.append(total)
            total += contour.count
        }
        let points = contours.flatMap { $0 }
        let loops: [[Int]] = contours.indices.compactMap { c in
            let loop = removeRepeats(Array(offsets[c] ..< offsets[c] + contours[c].count), points)
            return loop.count >= 3 && abs(signedArea(loop, points)) > 1e-12 ? loop : nil
        }
        guard !loops.isEmpty else { return [] }

        // Contours that cross each other have no nesting to go by; the exact even-odd fill would need the plane cut
        // up at the crossings. Each is filled on its own instead: their union.
        if loops.count > 1, contoursCross(loops, points) {
            return loops.flatMap { loop in
                clipEars(signedArea(loop, points) < 0 ? loop.reversed() : loop, points)
            }
        }

        // Depth: how many other contours each one is inside.
        let depth = loops.indices.map { i in
            loops.indices.filter { j in j != i && contains(loops[j], points[loops[i][0]], points) }.count
        }
        var triangles: [SIMD3<Int>] = []
        for i in loops.indices where depth[i] % 2 == 0 {
            // The outer contour counter-clockwise, its holes (one level in, and inside it) clockwise.
            var outer = loops[i]
            if signedArea(outer, points) < 0 { outer.reverse() }
            var holes: [[Int]] = loops.indices.compactMap { j in
                guard depth[j] == depth[i] + 1, contains(loops[i], points[loops[j][0]], points) else { return nil }
                var hole = loops[j]
                if signedArea(hole, points) > 0 { hole.reverse() }
                return hole
            }
            // Bridge the holes in from the rightmost first, so each bridge stays clear of those to come.
            holes.sort { maxX($0, points) > maxX($1, points) }
            for hole in holes {
                outer = bridge(hole, into: outer, points)
            }
            triangles += clipEars(outer, points)
        }
        return triangles
    }

    // MARK: Ear clipping

    private static func clipEars(_ polygon: [Int], _ points: [SIMD2<Float>]) -> [SIMD3<Int>] {
        var remaining = polygon
        var triangles: [SIMD3<Int>] = []
        var guardCount = 0
        while remaining.count > 3, guardCount < polygon.count * polygon.count + 16 {
            guardCount += 1
            let count = remaining.count
            var clipped = false
            for i in 0..<count {
                let prev = remaining[(i + count - 1) % count], current = remaining[i], next = remaining[(i + 1) % count]
                let a = points[prev], b = points[current], c = points[next]
                guard cross(a, b, c) > 1e-12 else { continue }
                // No other point may lie inside; bridge duplicates at a corner don't count.
                let blocked = remaining.contains { k in
                    guard k != prev, k != current, k != next else { return false }
                    let p = points[k]
                    if p == a || p == b || p == c { return false }
                    return inTriangle(p, a, b, c)
                }
                guard !blocked else { continue }
                triangles.append(SIMD3(prev, current, next))
                remaining.remove(at: i)
                clipped = true
                break
            }
            if !clipped {
                // Degenerate or self-touching: drop a vertex where the turn is flattest, so the rest still fills.
                let count = remaining.count
                let flattest = (0..<count).min { i, j in
                    abs(cross(points[remaining[(i + count - 1) % count]], points[remaining[i]], points[remaining[(i + 1) % count]]))
                        < abs(cross(points[remaining[(j + count - 1) % count]], points[remaining[j]], points[remaining[(j + 1) % count]]))
                } ?? 0
                let prev = remaining[(flattest + count - 1) % count], next = remaining[(flattest + 1) % count]
                if cross(points[prev], points[remaining[flattest]], points[next]) > 0 {
                    triangles.append(SIMD3(prev, remaining[flattest], next))
                }
                remaining.remove(at: flattest)
            }
        }
        if remaining.count == 3, cross(points[remaining[0]], points[remaining[1]], points[remaining[2]]) > 1e-12 {
            triangles.append(SIMD3(remaining[0], remaining[1], remaining[2]))
        }
        return triangles
    }

    // MARK: Holes

    /// Joins a hole into the outer polygon by a pair of edges from the hole's rightmost point to a point of the
    /// outer polygon it can see (Eberly's method).
    private static func bridge(_ hole: [Int], into outer: [Int], _ points: [SIMD2<Float>]) -> [Int] {
        guard let holeStart = hole.indices.max(by: { points[hole[$0]].x < points[hole[$1]].x }) else { return outer }
        let m = points[hole[holeStart]]
        // The nearest edge a ray to the right from m crosses, and where.
        var nearest = Float.infinity
        var edge: Int?
        var hit = m
        for i in outer.indices {
            let a = points[outer[i]], b = points[outer[(i + 1) % outer.count]]
            guard (a.y > m.y) != (b.y > m.y) || (a.y == m.y && b.y == m.y) else { continue }
            let t = a.y == b.y ? 0 : (m.y - a.y) / (b.y - a.y)
            let x = a.x + (b.x - a.x) * t
            if x >= m.x, x - m.x < nearest {
                nearest = x - m.x
                edge = i
                hit = SIMD2(x, m.y)
            }
        }
        var target: Int
        if let edge {
            let i0 = edge, i1 = (edge + 1) % outer.count
            target = points[outer[i0]].x > points[outer[i1]].x ? i0 : i1
            // A reflex vertex inside the triangle m, hit, target may block the view: take the one at the smallest
            // angle from the ray instead.
            let p = points[outer[target]]
            var best = Float.infinity
            for k in outer.indices where k != target {
                let q = points[outer[k]]
                guard q.x >= m.x, inTriangle(q, m, hit, p) || inTriangle(q, m, p, hit) else { continue }
                let prev = points[outer[(k + outer.count - 1) % outer.count]], next = points[outer[(k + 1) % outer.count]]
                guard cross(prev, q, next) <= 0 else { continue }
                let d = q - m
                let angle = abs(d.y) / max(sqrtLength(d), 1e-20)
                if angle < best {
                    best = angle
                    target = k
                }
            }
        } else {
            // No edge to the right (a malformed hole outside): join to the nearest outer point.
            target = outer.indices.min { sqrtLength(points[outer[$0]] - m) < sqrtLength(points[outer[$1]] - m) } ?? 0
        }
        let rotatedHole = Array(hole[holeStart...] + hole[..<holeStart])
        return Array(outer[...target]) + rotatedHole + [hole[holeStart], outer[target]] + Array(outer[(target + 1)...])
    }

    // MARK: Helpers

    /// Whether an edge of one contour properly crosses an edge of another.
    private static func contoursCross(_ loops: [[Int]], _ points: [SIMD2<Float>]) -> Bool {
        func edges(_ loop: [Int]) -> [(SIMD2<Float>, SIMD2<Float>)] {
            loop.indices.map { (points[loop[$0]], points[loop[($0 + 1) % loop.count]]) }
        }
        let all = loops.map(edges)
        for i in all.indices {
            for j in (i + 1) ..< all.count {
                for (a, b) in all[i] {
                    for (c, d) in all[j] {
                        let d1 = cross(c, d, a), d2 = cross(c, d, b), d3 = cross(a, b, c), d4 = cross(a, b, d)
                        if ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0)) {
                            return true
                        }
                    }
                }
            }
        }
        return false
    }

    /// A polygon's normal by Newell's method, which holds for concave and slightly non-planar polygons.
    public static func newellNormal(_ points: [SIMD3<Float>]) -> SIMD3<Float> {
        var n = SIMD3<Float>.zero
        for i in points.indices {
            let a = points[i], b = points[(i + 1) % points.count]
            n += SIMD3((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y))
        }
        return n.normalized
    }

    private static func cross(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Float {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }

    private static func inTriangle(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Bool {
        cross(a, b, p) >= 0 && cross(b, c, p) >= 0 && cross(c, a, p) >= 0
    }

    private static func signedArea(_ loop: [Int], _ points: [SIMD2<Float>]) -> Float {
        var area: Float = 0
        for i in loop.indices {
            let a = points[loop[i]], b = points[loop[(i + 1) % loop.count]]
            area += a.x * b.y - b.x * a.y
        }
        return area / 2
    }

    /// Whether a point is inside a loop, by the even-odd rule.
    private static func contains(_ loop: [Int], _ p: SIMD2<Float>, _ points: [SIMD2<Float>]) -> Bool {
        var inside = false
        for i in loop.indices {
            let a = points[loop[i]], b = points[loop[(i + 1) % loop.count]]
            if (a.y > p.y) != (b.y > p.y), p.x < a.x + (b.x - a.x) * (p.y - a.y) / (b.y - a.y) {
                inside.toggle()
            }
        }
        return inside
    }

    private static func removeRepeats(_ loop: [Int], _ points: [SIMD2<Float>]) -> [Int] {
        var result: [Int] = []
        for index in loop where result.last.map({ points[$0] != points[index] }) ?? true {
            result.append(index)
        }
        while result.count > 1, points[result[0]] == points[result[result.count - 1]] { result.removeLast() }
        return result
    }

    private static func maxX(_ loop: [Int], _ points: [SIMD2<Float>]) -> Float {
        loop.map { points[$0].x }.max() ?? 0
    }

    private static func sqrtLength(_ v: SIMD2<Float>) -> Float {
        (v * v).sum().squareRoot()
    }

    private static func abs(_ v: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(Swift.abs(v.x), Swift.abs(v.y), Swift.abs(v.z))
    }

    private static func abs(_ x: Float) -> Float { Swift.abs(x) }
}
