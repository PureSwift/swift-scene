import Testing
import SceneCore
@testable import SceneGraph

@Suite struct QuadricSurfaceTests {

    private func faceTriangles(_ mesh: MeshBuffer, _ part: QuadricSurface.Part) -> [SIMD3<Int>] {
        mesh.triangles(in: mesh.submeshes[part.rawValue])
    }

    /// Every triangle of a part faces away from a point inside the solid.
    private func facesAway(_ mesh: MeshBuffer, _ part: QuadricSurface.Part, from inside: SIMD3<Float>) -> Bool {
        let positions = mesh.positions
        return faceTriangles(mesh, part).allSatisfy { t in
            let a = positions[t.x], b = positions[t.y], c = positions[t.z]
            return (b - a).cross(c - a).dot((a + b + c) / 3 - inside) > 0
        }
    }

    @Test func ellipsoidSpansItsAxes() {
        let mesh = QuadricSurface(.ellipsoid, orientation: SIMD3(0, 2, 0), majorRadius: SIMD3(1, 0, 0), minorRadius: SIMD3(0, 0, 3)).makeMesh()
        #expect(mesh.bounds.max.y == 2 && mesh.bounds.min.y == -2)
        #expect(abs(mesh.bounds.max.z - 3) < 0.01)
        #expect(facesAway(mesh, .face, from: .zero))
        // Closed: no caps.
        #expect(faceTriangles(mesh, .topCap).isEmpty && faceTriangles(mesh, .interiorCap).isEmpty)
    }

    @Test func leftHandedAxesStillFaceOut() {
        // Major and minor swapped: the frame is left-handed, as Quesa's "Flipped" samples are.
        let mesh = QuadricSurface(.ellipsoid, orientation: SIMD3(0, 1, 0), majorRadius: SIMD3(0, 0, 1), minorRadius: SIMD3(1, 0, 0)).makeMesh()
        #expect(facesAway(mesh, .face, from: .zero))
        let normals = mesh.stream(.normal)!
        let positions = mesh.positions
        #expect(positions.indices.allSatisfy { i in SIMD3(normals[i].map { $0 }).dot(positions[i]) > 0 })
    }

    @Test func cylinderCapsCloseIt() {
        // Orientation y needs radii z and x to stay right-handed and round.
        let surface = QuadricSurface(.cylinder, orientation: SIMD3(0, 2, 0), majorRadius: SIMD3(0, 0, 1), minorRadius: SIMD3(1, 0, 0), caps: [.top, .bottom])
        let mesh = surface.makeMesh()
        let inside = SIMD3<Float>(0, 1, 0)
        #expect(facesAway(mesh, .face, from: inside))
        #expect(facesAway(mesh, .topCap, from: inside))
        #expect(facesAway(mesh, .bottomCap, from: inside))
        #expect(faceTriangles(mesh, .topCap).count == 16)
    }

    @Test func partialSweepWrapsAndHasInteriorCaps() {
        // From 0.85 round past 1 to 0.15, as Quesa's partial cone sample is.
        let surface = QuadricSurface(.cone, orientation: SIMD3(0, 4, 0), majorRadius: SIMD3(0, 0, 1), minorRadius: SIMD3(3, 0, 0),
                                     uMin: 0.85, uMax: 0.15, vMax: 0.6, caps: [.bottom, .interior])
        let mesh = surface.makeMesh()
        #expect(!faceTriangles(mesh, .interiorCap).isEmpty)
        #expect(faceTriangles(mesh, .topCap).isEmpty)
        // The wedge is round the major radius (+z), so nothing reaches far toward -z.
        #expect(mesh.bounds.min.z > 0.5 * -0.01 - 0.01)
        #expect(facesAway(mesh, .bottomCap, from: SIMD3(0, 1, 0.5)))
    }

    @Test func coneApexAndDisk() {
        let cone = QuadricSurface(.cone, orientation: SIMD3(0, 1, 0), majorRadius: SIMD3(0, 0, 1), minorRadius: SIMD3(1, 0, 0), caps: [.bottom]).makeMesh()
        #expect(abs(cone.bounds.max.y - 1) < 1e-5)
        #expect(facesAway(cone, .bottomCap, from: SIMD3(0, 0.25, 0)))
        let disk = QuadricSurface(.disk).makeMesh()
        let normals = disk.stream(.normal)!
        // A disk faces major × minor: +z for QuickDraw 3D's default.
        #expect(Array(normals[0]) == [0, 0, 1])
        #expect(faceTriangles(disk, .face).count == 16)
    }

    @Test func torusTube() {
        let mesh = QuadricSurface(.torus(ratio: 0.5), orientation: SIMD3(0, 1, 0), majorRadius: SIMD3(2, 0, 0), minorRadius: SIMD3(0, 0, 2)).makeMesh(uSegments: 32, vSegments: 16)
        // The tube is the orientation's length high, and the ratio of that wide.
        #expect(abs(mesh.bounds.max.y - 1) < 1e-4)
        #expect(abs(mesh.bounds.max.x - 2.5) < 0.01)
    }

    @Test func degenerateIsEmpty() {
        #expect(QuadricSurface(.ellipsoid, majorRadius: .zero).makeMesh().vertexCount == 0)
        #expect(QuadricSurface(.cylinder, uMin: 0.5, uMax: 0.5).makeMesh().vertexCount == 0)
    }
}
