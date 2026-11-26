import Testing
@testable import SceneCore

func isClose(_ a: Float, _ b: Float, tolerance: Float = 1e-4) -> Bool { abs(a - b) <= tolerance }

func isClose(_ a: SIMD3<Float>, _ b: SIMD3<Float>, tolerance: Float = 1e-4) -> Bool {
    isClose(a.x, b.x, tolerance: tolerance) && isClose(a.y, b.y, tolerance: tolerance) && isClose(a.z, b.z, tolerance: tolerance)
}

func isClose(_ a: Matrix4x4, _ b: Matrix4x4, tolerance: Float = 1e-4) -> Bool {
    zip(a.columnMajorElements, b.columnMajorElements).allSatisfy { isClose($0, $1, tolerance: tolerance) }
}

@Suite struct QuaternionTests {

    @Test func rotatesAboutAxis() {
        let q = Quaternion(angle: .pi / 2, axis: SIMD3(0, 1, 0))
        #expect(isClose(q.act(SIMD3(1, 0, 0)), SIMD3(0, 0, -1)))
        #expect(isClose(Matrix4x4(rotation: q).transformDirection(SIMD3(1, 0, 0)), SIMD3(0, 0, -1)))
    }

    @Test func productAppliesRightFirst() {
        let yaw = Quaternion(angle: .pi / 2, axis: SIMD3(0, 1, 0))
        let pitch = Quaternion(angle: .pi / 2, axis: SIMD3(1, 0, 0))
        let v = SIMD3<Float>(0, 0, -1)
        #expect(isClose((yaw * pitch).act(v), yaw.act(pitch.act(v))))
    }

    @Test(arguments: [
        SIMD3<Float>(0.3, -0.7, 1.1),
        SIMD3<Float>(-1.2, 0.4, 0),
        SIMD3<Float>(0, 0.5, -2.5),
    ])
    func eulerAnglesRoundTrip(_ angles: SIMD3<Float>) {
        let q = Quaternion(eulerAngles: angles)
        #expect(isClose(Quaternion(eulerAngles: q.eulerAngles).act(SIMD3(1, 2, 3)), q.act(SIMD3(1, 2, 3))))
    }

    @Test func sceneKitQuarterTurnReadsBackOtherWay() {
        let q = Quaternion(angle: .pi / 2, axis: SIMD3(0, 1, 0))
        #expect(isClose(q.eulerAngles(sceneKitReadBack: false).y, .pi / 2))
        #expect(isClose(q.eulerAngles(sceneKitReadBack: true).y, -.pi / 2))
    }

    @Test func rotationMatrixRoundTrip() {
        let q = Quaternion(angle: 2.1, axis: SIMD3(1, -2, 0.5)).normalized
        let back = Quaternion(rotationMatrix: Matrix4x4(rotation: q))
        // q and -q are the same rotation.
        #expect(abs(back.vector.dot(q.vector)) > 0.9999)
    }

    @Test func slerpHalfway() {
        let a = Quaternion.identity, b = Quaternion(angle: .pi / 2, axis: SIMD3(0, 0, 1))
        let half = Quaternion.slerp(from: a, to: b, t: 0.5)
        #expect(isClose(half.angle, .pi / 4))
    }

    @Test func fromToRotation() {
        let q = Quaternion(from: SIMD3(1, 0, 0), to: SIMD3(0, 1, 0))
        #expect(isClose(q.act(SIMD3(1, 0, 0)), SIMD3(0, 1, 0)))
        let opposite = Quaternion(from: SIMD3(0, 0, 1), to: SIMD3(0, 0, -1))
        #expect(isClose(opposite.act(SIMD3(0, 0, 1)), SIMD3(0, 0, -1)))
    }
}

@Suite struct MatrixTests {

    @Test func inverseOfTransform() throws {
        let m = Transform(scale: SIMD3(2, 3, 0.5), rotation: Quaternion(angle: 0.7, axis: SIMD3(1, 1, 0)), translation: SIMD3(4, -2, 9)).matrix
        let inverse = try #require(m.inverse)
        #expect(isClose(m * inverse, .identity))
        #expect(isClose(m.determinant, 3))
    }

    @Test func singularHasNoInverse() {
        #expect(Matrix4x4(scale: SIMD3(1, 0, 1)).inverse == nil)
    }

    @Test func rowMajorIsTranspose() {
        let elements = (0..<16).map(Float.init)
        let m = Matrix4x4(rowMajor: elements)
        #expect(m[0, 1] == 1)
        #expect(m[1, 0] == 4)
        #expect(m.rowMajorElements == elements)
        #expect(Matrix4x4(columnMajor: elements) == m.transpose)
    }

    @Test func quickDraw3DTranslationIsInLastRow() {
        // A QD3D translation: identity with the offset in row 3, acting on row vectors.
        var rows = Matrix4x4.identity.columnMajorElements
        rows[12] = 5; rows[13] = 6; rows[14] = 7
        let m = Matrix4x4(quickDraw3D: rows)
        #expect(m.translation == SIMD3(5, 6, 7))
        #expect(m.transformPoint(.zero) == SIMD3(5, 6, 7))
        #expect(m.quickDraw3DElements == rows)
    }

    @Test func transformDecomposes() {
        let t = Transform(scale: SIMD3(1, 2, 3), rotation: Quaternion(angle: 1, axis: SIMD3(0, 1, 0)), translation: SIMD3(1, 2, 3))
        let back = Transform(matrix: t.matrix)
        #expect(isClose(back.scale, t.scale))
        #expect(isClose(back.translation, t.translation))
        #expect(isClose(back.matrix, t.matrix))
    }

    @Test func lookAtLooksDownNegativeZ() {
        let view = Matrix4x4.lookAt(eye: SIMD3(0, 0, 5), target: .zero, up: SIMD3(0, 1, 0))
        #expect(isClose(view.transformPoint(.zero), SIMD3(0, 0, -5)))
    }

    @Test func perspectiveMapsNearAndFar() {
        let p = Matrix4x4.perspective(verticalFieldOfView: .pi / 2, aspectRatio: 1, near: 1, far: 10)
        #expect(isClose(p.projectPoint(SIMD3(0, 0, -1)).z, -1))
        #expect(isClose(p.projectPoint(SIMD3(0, 0, -10)).z, 1))
    }
}

@Suite struct BoundsTests {

    @Test func boxUnionAndTransform() {
        var box = BoundingBox.empty
        #expect(box.isEmpty)
        box.formUnion(SIMD3(-1, -1, -1))
        box.formUnion(SIMD3(1, 1, 1))
        #expect(box.extents == SIMD3(2, 2, 2))
        let moved = box.transformed(by: Matrix4x4(translation: SIMD3(10, 0, 0)) * Matrix4x4(rotation: Quaternion(angle: .pi / 4, axis: SIMD3(0, 1, 0))))
        #expect(isClose(moved.center, SIMD3(10, 0, 0)))
        #expect(isClose(moved.extents.x, 2 * 2.0.squareRoot().asFloat))
    }

    @Test func rayHitsBoxSphereAndTriangle() {
        let ray = Ray(origin: SIMD3(0, 0, 5), direction: SIMD3(0, 0, -1))
        #expect(ray.intersection(with: BoundingBox(min: SIMD3(repeating: -1), max: SIMD3(repeating: 1))) == 4)
        #expect(ray.intersection(with: BoundingSphere(center: .zero, radius: 2)) == 3)
        let hit = ray.intersection(withTriangle: SIMD3(-1, -1, 0), SIMD3(1, -1, 0), SIMD3(0, 1, 0))
        #expect(hit?.distance == 5)
        #expect(ray.intersection(withTriangle: SIMD3(2, 2, 0), SIMD3(3, 2, 0), SIMD3(2, 3, 0)) == nil)
    }

    @Test func frustumCulls() {
        let view = Matrix4x4.lookAt(eye: SIMD3(0, 0, 5), target: .zero, up: SIMD3(0, 1, 0))
        let projection = Matrix4x4.perspective(verticalFieldOfView: .pi / 3, aspectRatio: 1, near: 0.1, far: 100)
        let frustum = Frustum(viewProjection: projection * view)
        #expect(frustum.contains(.zero))
        #expect(frustum.intersects(BoundingBox(min: SIMD3(repeating: -1), max: SIMD3(repeating: 1))))
        #expect(!frustum.intersects(BoundingBox(min: SIMD3(50, 0, 0), max: SIMD3(51, 1, 1))))
        #expect(!frustum.intersects(BoundingSphere(center: SIMD3(0, 0, 10), radius: 1)))
    }
}

private extension Double {
    var asFloat: Float { Float(self) }
}
