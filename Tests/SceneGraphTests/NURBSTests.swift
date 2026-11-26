import Testing
import SceneCore
@testable import SceneGraph

@Suite struct NURBSTests {

    @Test func clampedCurveReachesItsEnds() {
        // A quadratic with clamped knots passes through its first and last control points.
        let curve = NURBSCurve(order: 3, controlPoints: [SIMD4(0, 0, 0, 1), SIMD4(1, 2, 0, 1), SIMD4(2, 0, 0, 1)], knots: [0, 0, 0, 1, 1, 1])
        #expect(curve.point(at: 0) == SIMD3(0, 0, 0))
        #expect(curve.point(at: 1) == SIMD3(2, 0, 0))
        // Halfway: the quadratic Bézier's midpoint.
        #expect(curve.point(at: 0.5) == SIMD3(1, 1, 0))
        let mesh = curve.makeMesh(segmentsPerSpan: 4)
        #expect(mesh.vertexCount == 5)
        #expect(mesh.submeshes.first?.primitive == .lineStrip)
    }

    @Test func weightsPullTowardTheirPoint() {
        // A rational quarter circle: the middle point weighted by √2/2, its coordinates multiplied by it.
        let w = Float(2).squareRoot() / 2
        let curve = NURBSCurve(order: 3, controlPoints: [SIMD4(1, 0, 0, 1), SIMD4(w, w, 0, w), SIMD4(0, 1, 0, 1)], knots: [0, 0, 0, 1, 1, 1])
        for u: Float in [0.1, 0.3, 0.5, 0.8] {
            #expect(abs(curve.point(at: u).length - 1) < 1e-5)
        }
    }

    @Test func bilinearPatchIsFlat() {
        let patch = NURBSPatch(
            uOrder: 2, vOrder: 2, rows: 2, columns: 2,
            controlPoints: [SIMD4(0, 0, 0, 1), SIMD4(1, 0, 0, 1), SIMD4(0, 1, 0, 1), SIMD4(1, 1, 0, 1)],
            uKnots: [0, 0, 1, 1], vKnots: [0, 0, 1, 1]
        )
        #expect(patch.point(u: 0.25, v: 0.75) == SIMD3(0.25, 0.75, 0))
        let mesh = patch.makeMesh(segmentsPerSpan: 4)
        #expect(mesh.vertexCount == 25)
        #expect(mesh.triangles(in: mesh.submeshes[0]).count == 32)
        // du × dv is +z.
        #expect(Array(mesh.stream(.normal)![0]) == [0, 0, 1])
    }

    @Test func invalidIsEmpty() {
        #expect(NURBSCurve(order: 3, controlPoints: [SIMD4(0, 0, 0, 1)], knots: [0, 1]).makeMesh().vertexCount == 0)
    }
}
