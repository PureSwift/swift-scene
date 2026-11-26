// Ported from Quesa's NURB geometries (E3GeometryNURBPatch.cpp, E3GeometryNURBCurve.cpp).
// Copyright (c) 1999-2021, Quesa Developers. All rights reserved.
// Licensed under the BSD 3-Clause License; see LICENSE-Quesa.

import SceneCore

/// A non-uniform rational B-spline curve: control points with weights in `w`, their x, y and z already multiplied by
/// it, as QuickDraw 3D's are; an order (one more than the degree); and order + count knots.
public struct NURBSCurve: Hashable, Sendable {

    public var order: Int
    public var controlPoints: [SIMD4<Float>]
    public var knots: [Float]

    public init(order: Int, controlPoints: [SIMD4<Float>], knots: [Float]) {
        self.order = order
        self.controlPoints = controlPoints
        self.knots = knots
    }

    public var isValid: Bool {
        order >= 2 && controlPoints.count >= order && knots.count == controlPoints.count + order
    }

    /// The curve's point at `u`, between the knots `order - 1` and `count`.
    public func point(at u: Float) -> SIMD3<Float> {
        var sum = SIMD4<Float>.zero
        for i in controlPoints.indices {
            let b = NURBSBasis.value(u, i, order, knots)
            if b != 0 { sum += controlPoints[i] * b }
        }
        return sum.w != 0 ? sum.xyz / sum.w : sum.xyz
    }

    /// The curve as a line strip, with `segments` lines for each span between distinct knots.
    public func makeMesh(segmentsPerSpan: Int = 8) -> MeshBuffer {
        guard isValid else { return .empty }
        let parameters = NURBSBasis.samples(knots, order: order, count: controlPoints.count, segmentsPerSpan: segmentsPerSpan)
        let points = parameters.map(point(at:))
        return MeshBuffer(
            vertexCount: points.count,
            streams: [VertexStream(semantic: .position, vectors: points)],
            submeshes: [Submesh(primitive: .lineStrip, range: 0 ..< points.count, materialIndex: 0)]
        )
    }
}

/// A non-uniform rational B-spline surface: a grid of weighted control points, `columns` of them a row along u,
/// with an order and knots for each direction, as QuickDraw 3D's NURB patches are. Trim curves aren't drawn.
public struct NURBSPatch: Hashable, Sendable {

    public var uOrder: Int
    public var vOrder: Int
    public var rows: Int
    public var columns: Int
    /// Row by row: `columns` points along u, `rows` times along v.
    public var controlPoints: [SIMD4<Float>]
    public var uKnots: [Float]
    public var vKnots: [Float]

    public init(uOrder: Int, vOrder: Int, rows: Int, columns: Int, controlPoints: [SIMD4<Float>], uKnots: [Float], vKnots: [Float]) {
        self.uOrder = uOrder
        self.vOrder = vOrder
        self.rows = rows
        self.columns = columns
        self.controlPoints = controlPoints
        self.uKnots = uKnots
        self.vKnots = vKnots
    }

    public var isValid: Bool {
        uOrder >= 2 && vOrder >= 2 && columns >= uOrder && rows >= vOrder
            && controlPoints.count == rows * columns
            && uKnots.count == columns + uOrder && vKnots.count == rows + vOrder
    }

    /// The surface's point at (u, v): the weighted sum over the basis in both directions, divided by the weights'.
    public func point(u: Float, v: Float) -> SIMD3<Float> {
        let uBasis = (0..<columns).map { NURBSBasis.value(u, $0, uOrder, uKnots) }
        let vBasis = (0..<rows).map { NURBSBasis.value(v, $0, vOrder, vKnots) }
        var sum = SIMD4<Float>.zero
        for j in 0..<rows where vBasis[j] != 0 {
            for i in 0..<columns where uBasis[i] != 0 {
                sum += controlPoints[j * columns + i] * (uBasis[i] * vBasis[j])
            }
        }
        return sum.w != 0 ? sum.xyz / sum.w : sum.xyz
    }

    /// The surface as triangles, `segmentsPerSpan` for each span between distinct knots in each direction. The face
    /// is the side du × dv points to.
    public func makeMesh(segmentsPerSpan: Int = 8) -> MeshBuffer {
        guard isValid else { return .empty }
        let us = NURBSBasis.samples(uKnots, order: uOrder, count: columns, segmentsPerSpan: segmentsPerSpan)
        let vs = NURBSBasis.samples(vKnots, order: vOrder, count: rows, segmentsPerSpan: segmentsPerSpan)
        let uRange = (us.first ?? 0, us.last ?? 1), vRange = (vs.first ?? 0, vs.last ?? 1)
        let hu = max((uRange.1 - uRange.0) * 1e-3, 1e-6), hv = max((vRange.1 - vRange.0) * 1e-3, 1e-6)
        var mesh = MeshAccumulator()
        for v in vs {
            for u in us {
                let p = point(u: u, v: v)
                // One-sided differences at the ends, staying within the knots.
                let u0 = max(u - hu, uRange.0), u1 = min(u + hu, uRange.1)
                let v0 = max(v - hv, vRange.0), v1 = min(v + hv, vRange.1)
                var normal = (point(u: u1, v: v) - point(u: u0, v: v)).cross(point(u: u, v: v1) - point(u: u, v: v0)).normalized
                if normal.lengthSquared == 0 { normal = SIMD3(0, 0, 1) }
                let uv = SIMD2((u - uRange.0) / max(uRange.1 - uRange.0, 1e-20), 1 - (v - vRange.0) / max(vRange.1 - vRange.0, 1e-20))
                mesh.vertex(p, normal, uv)
            }
        }
        let row = us.count
        for j in 0 ..< vs.count - 1 {
            for i in 0 ..< us.count - 1 {
                let a = j * row + i, b = a + 1, c = a + row + 1, d = a + row
                mesh.triangle(a, b, c)
                mesh.triangle(a, c, d)
            }
        }
        return mesh.build(submeshes: [Submesh(range: 0 ..< mesh.indices.count, materialIndex: 0)])
    }
}

/// B-spline basis functions, by Cox and de Boor's recursion.
enum NURBSBasis {

    /// The basis function i of order k at u. Each span is half-open but the last, so the curve reaches its end.
    static func value(_ u: Float, _ i: Int, _ k: Int, _ knots: [Float]) -> Float {
        if k == 1 {
            let lastSpan = knots.lastIndex { $0 < knots[knots.count - 1] } ?? 0
            if knots[i] <= u, u < knots[i + 1] { return 1 }
            // At the very end, the last non-empty span holds it.
            return u == knots[knots.count - 1] && i == lastSpan ? 1 : 0
        }
        var result: Float = 0
        let left = knots[i + k - 1] - knots[i]
        if left > 1e-12 {
            let fraction = (u - knots[i]) / left
            if fraction > 0 { result += fraction * value(u, i, k - 1, knots) }
        }
        let right = knots[i + k] - knots[i + 1]
        if right > 1e-12 {
            let fraction = (knots[i + k] - u) / right
            if fraction > 0 { result += fraction * value(u, i + 1, k - 1, knots) }
        }
        return result
    }

    /// Parameters across the curve's domain, from knot `order - 1` to knot `count`: each non-empty span cut into
    /// `segmentsPerSpan`.
    static func samples(_ knots: [Float], order: Int, count: Int, segmentsPerSpan: Int) -> [Float] {
        let segments = max(segmentsPerSpan, 1)
        var result: [Float] = []
        for span in (order - 1) ..< count {
            let a = knots[span], b = knots[span + 1]
            guard b > a else { continue }
            for s in 0..<segments { result.append(a + (b - a) * Float(s) / Float(segments)) }
        }
        result.append(knots[count])
        return result
    }
}
