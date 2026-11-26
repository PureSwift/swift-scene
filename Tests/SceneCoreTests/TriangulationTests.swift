import Testing
@testable import SceneCore

@Suite struct TriangulationTests {

    private func area(_ triangles: [SIMD3<Int>], _ points: [SIMD2<Float>]) -> Float {
        triangles.reduce(0) { sum, t in
            let a = points[t.x], b = points[t.y], c = points[t.z]
            return sum + ((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)) / 2
        }
    }

    @Test func convexSquare() {
        let square: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]
        let triangles = Triangulation.triangulate([square])
        #expect(triangles.count == 2)
        #expect(abs(area(triangles, square) - 1) < 1e-6)
    }

    @Test func clockwiseInputComesOutCounterClockwise() {
        let square: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(0, 1), SIMD2(1, 1), SIMD2(1, 0)]
        #expect(abs(area(Triangulation.triangulate([square]), square) - 1) < 1e-6)
    }

    @Test func concaveL() {
        let l: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(2, 0), SIMD2(2, 1), SIMD2(1, 1), SIMD2(1, 2), SIMD2(0, 2)]
        let triangles = Triangulation.triangulate([l])
        #expect(triangles.count == 4)
        #expect(abs(area(triangles, l) - 3) < 1e-6)
    }

    @Test func squareWithHole() {
        let outer: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(4, 0), SIMD2(4, 4), SIMD2(0, 4)]
        let hole: [SIMD2<Float>] = [SIMD2(1, 1), SIMD2(3, 1), SIMD2(3, 3), SIMD2(1, 3)]
        let points = outer + hole
        let triangles = Triangulation.triangulate([outer, hole])
        #expect(abs(area(triangles, points) - 12) < 1e-5)
        // Nothing covers the hole's middle.
        let middle = SIMD2<Float>(2, 2)
        let covered = triangles.contains { t in
            let a = points[t.x], b = points[t.y], c = points[t.z]
            func side(_ p: SIMD2<Float>, _ q: SIMD2<Float>) -> Float { (q.x - p.x) * (middle.y - p.y) - (q.y - p.y) * (middle.x - p.x) }
            return side(a, b) > 0 && side(b, c) > 0 && side(c, a) > 0
        }
        #expect(!covered)
    }

    @Test func islandInsideHole() {
        let outer: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(6, 0), SIMD2(6, 6), SIMD2(0, 6)]
        let hole: [SIMD2<Float>] = [SIMD2(1, 1), SIMD2(5, 1), SIMD2(5, 5), SIMD2(1, 5)]
        let island: [SIMD2<Float>] = [SIMD2(2, 2), SIMD2(4, 2), SIMD2(4, 4), SIMD2(2, 4)]
        let triangles = Triangulation.triangulate([outer, hole, island])
        #expect(abs(area(triangles, outer + hole + island) - (36 - 16 + 4)) < 1e-4)
    }

    @Test func projectsFromAnyPlane() {
        // A square in the plane of x and z, wound counter-clockwise seen from -y.
        let square: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 0, 1), SIMD3(0, 0, 1)]
        let normal = Triangulation.newellNormal(square)
        #expect(normal == SIMD3(0, -1, 0))
        for t in Triangulation.triangulate([square]) {
            let a = square[t.x], b = square[t.y], c = square[t.z]
            #expect((b - a).cross(c - a).dot(normal) > 0)
        }
    }
}

extension TriangulationTests {

    @Test func crossingContoursFillEach() {
        // Two triangles making a star, as Quesa's GeneralPolygon_ComplexG sample does.
        let up: [SIMD2<Float>] = [SIMD2(0, 2), SIMD2(-2, -3), SIMD2(2, -3)]
        let down: [SIMD2<Float>] = [SIMD2(0, -2), SIMD2(2, 3), SIMD2(-2, 3)]
        let triangles = Triangulation.triangulate([up, down])
        #expect(triangles.count == 2)
        #expect(area(triangles, up + down) > 0)
    }
}
