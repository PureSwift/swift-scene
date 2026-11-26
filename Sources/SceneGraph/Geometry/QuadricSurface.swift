// Ported from Quesa's quadric geometries (E3GeometryEllipsoid.cpp, E3GeometryCone.cpp, E3GeometryCylinder.cpp,
// E3GeometryDisk.cpp, E3GeometryTorus.cpp).
// Copyright (c) 1999-2021, Quesa Developers. All rights reserved.
// Licensed under the BSD 3-Clause License; see LICENSE-Quesa.

import SceneCore

/// QuickDraw 3D's quadric surfaces: an ellipsoid, cone, cylinder, disk or torus, each placed by an origin and
/// three axis vectors (orientation, major and minor radius) rather than by sizes, so it may be squashed or sheared,
/// and swept over part of its parameter ranges, with caps closing what is left open.
///
/// The parameters run from 0 to 1. u goes round the orientation axis, from the major radius toward the minor;
/// v goes along it: from the south pole to the north for an ellipsoid, from the base to the apex for a cone, from
/// the base to the top for a cylinder, out from the middle for a disk, and round the tube for a torus.
public struct QuadricSurface: Hashable, Sendable {

    public enum Kind: Hashable, Sendable {
        case ellipsoid
        case cone
        case cylinder
        case disk
        /// The tube's cross-section is an ellipse as high as the orientation is long, and `ratio` times that wide.
        case torus(ratio: Float)
    }

    /// Which ends a partial surface is closed at.
    public struct Caps: OptionSet, Hashable, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        /// The end at the largest v.
        public static let top = Caps(rawValue: 1 << 0)
        /// The end at the smallest v.
        public static let bottom = Caps(rawValue: 1 << 1)
        /// The planes at the ends of a partial sweep in u.
        public static let interior = Caps(rawValue: 1 << 2)
    }

    /// The submeshes a surface's mesh always has, some of them empty, in material order.
    public enum Part: Int, CaseIterable, Sendable {
        case face, topCap, bottomCap, interiorCap
    }

    public var kind: Kind
    public var origin: SIMD3<Float>
    /// The axis: for a disk, unused.
    public var orientation: SIMD3<Float>
    public var majorRadius: SIMD3<Float>
    public var minorRadius: SIMD3<Float>
    public var uMin: Float
    public var uMax: Float
    public var vMin: Float
    public var vMax: Float
    public var caps: Caps

    /// A surface; the defaults are QuickDraw 3D's: a unit shape at the origin, its orientation x, its radii y and z.
    public init(
        _ kind: Kind,
        origin: SIMD3<Float> = .zero,
        orientation: SIMD3<Float> = SIMD3(1, 0, 0),
        majorRadius: SIMD3<Float>? = nil,
        minorRadius: SIMD3<Float>? = nil,
        uMin: Float = 0, uMax: Float = 1, vMin: Float = 0, vMax: Float = 1,
        caps: Caps = []
    ) {
        self.kind = kind
        self.origin = origin
        self.orientation = orientation
        // A disk has no orientation, so its radii are QuickDraw 3D's x and y.
        self.majorRadius = majorRadius ?? (kind == .disk ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0))
        self.minorRadius = minorRadius ?? (kind == .disk ? SIMD3(0, 1, 0) : SIMD3(0, 0, 1))
        self.uMin = uMin
        self.uMax = uMax
        self.vMin = vMin
        self.vMax = vMax
        self.caps = caps
    }

    // MARK: Parameterization

    /// The radial vector at u: cos(2πu) major + sin(2πu) minor.
    private func radial(_ u: Float) -> SIMD3<Float> {
        let angle = 2 * Float.pi * u
        return majorRadius * Elementary.cos(angle) + minorRadius * Elementary.sin(angle)
    }

    /// The surface's point at (u, v).
    func point(_ u: Float, _ v: Float) -> SIMD3<Float> {
        switch kind {
        case .ellipsoid:
            return origin + radial(u) * Elementary.sin(.pi * v) - orientation * Elementary.cos(.pi * v)
        case .cone:
            return origin + orientation * v + radial(u) * (1 - v)
        case .cylinder:
            return origin + orientation * v + radial(u)
        case .disk:
            return origin + radial(u) * v
        case .torus(let ratio):
            let axis = radial(u), length = axis.length
            let angle = 2 * Float.pi * v
            let tube = length > 0 ? ratio * orientation.length / length : 0
            return origin + axis - orientation * Elementary.sin(angle) - axis * (Elementary.cos(angle) * tube)
        }
    }

    /// The point on the axis level with v, which end caps fan from; nil for a disk or torus.
    private func axisPoint(_ v: Float) -> SIMD3<Float>? {
        switch kind {
        case .ellipsoid: origin - orientation * Elementary.cos(.pi * v)
        case .cone, .cylinder: origin + orientation * v
        case .disk, .torus: nil
        }
    }

    /// A direction away from the solid at a point, to turn normals outward.
    private func outward(_ u: Float, _ v: Float, _ p: SIMD3<Float>) -> SIMD3<Float> {
        switch kind {
        case .ellipsoid: p - origin
        case .cone, .cylinder: p - (axisPoint(v) ?? origin)
        case .disk: majorRadius.cross(minorRadius)
        case .torus: p - (origin + radial(u))
        }
    }

    /// The unit normal at (u, v), from the partial derivatives, turned outward. Where they vanish, at a pole or apex,
    /// the normal is taken a little way in from it.
    private func normal(_ u: Float, _ v: Float, toward center: Float) -> SIMD3<Float> {
        let h: Float = 1e-3
        let p = point(u, v)
        // Fractions of the way toward the middle of the v range.
        for nudge: Float in [0, 0.02, 0.2] {
            let vn = v + (center - v) * nudge
            let du = point(u + h, vn) - point(u - h, vn)
            let dv = point(u, vn + h) - point(u, vn - h)
            var n = du.cross(dv)
            guard n.lengthSquared > 1e-14 else { continue }
            n = n.normalized
            return n.dot(outward(u, v, p)) < 0 ? -n : n
        }
        return outward(u, v, p).normalized
    }

    // MARK: Mesh

    /// The surface as triangles, with `uSegments` round and `vSegments` along; QuickDraw 3D draws 16 by 8 unless a
    /// subdivision style says otherwise. The submeshes are the `Part`s, in order: face, top, bottom and interior caps.
    public func makeMesh(uSegments: Int = 16, vSegments: Int = 8) -> MeshBuffer {
        // Ranges as Quesa takes them: clamped, v in order, and a u range that wraps past 1 when it starts after it ends.
        var u0 = min(max(uMin, 0), 1), u1 = min(max(uMax, 0), 1)
        var v0 = min(max(vMin, 0), 1), v1 = min(max(vMax, 0), 1)
        if v0 > v1 { swap(&v0, &v1) }
        if u0 > u1 { u1 += 1 }
        guard abs(u1 - u0) > 1e-6, abs(v1 - v0) > 1e-6, majorRadius.cross(minorRadius).lengthSquared > 0 else { return .empty }
        let uCount = max(uSegments, 3)
        let vCount = kind == .cylinder || kind == .disk ? max(vSegments / 8, 1) : max(vSegments, 3)
        let isCircleComplete = abs(u1 - u0 - 1) < 1e-6
        let uMid = (u0 + u1) / 2, vMid = (v0 + v1) / 2

        var mesh = MeshAccumulator()

        // The face: a grid of vertices, two triangles a cell, each wound to face the way its normals do.
        let faceStart = mesh.indices.count
        let gridStart = mesh.count
        for j in 0...vCount {
            let v = v0 + (v1 - v0) * Float(j) / Float(vCount)
            for i in 0...uCount {
                let u = u0 + (u1 - u0) * Float(i) / Float(uCount)
                mesh.vertex(point(u, v), normal(u, v, toward: vMid), SIMD2(Float(i) / Float(uCount), 1 - Float(j) / Float(vCount)))
            }
        }
        let row = uCount + 1
        for j in 0..<vCount {
            for i in 0..<uCount {
                let a = gridStart + j * row + i, b = a + 1, c = a + row + 1, d = a + row
                mesh.triangle(a, b, c)
                mesh.triangle(a, c, d)
            }
        }
        let faceRange = faceStart ..< mesh.indices.count

        // An interior point, which caps face away from.
        let inside: SIMD3<Float> = switch kind {
        case .torus: origin + radial(uMid)
        default: ((axisPoint(vMid) ?? origin) + point(uMid, vMid)) / 2
        }

        // End caps: fans from the axis to the rim at an end that isn't a pole or apex.
        func endCap(_ v: Float) -> Range<Int> {
            let start = mesh.indices.count
            guard let center = axisPoint(v), (point(u0, v) - center).lengthSquared > 1e-12 else { return start..<start }
            var normal = orientation.normalized
            if normal.dot(center - inside) < 0 { normal = -normal }
            let hub = mesh.count
            mesh.vertex(center, normal, SIMD2(0.5, 0.5))
            for i in 0...uCount {
                let u = u0 + (u1 - u0) * Float(i) / Float(uCount)
                let angle = 2 * Float.pi * u
                mesh.vertex(point(u, v), normal, SIMD2((1 + Elementary.cos(angle)) / 2, (1 - Elementary.sin(angle)) / 2))
            }
            for i in 0..<uCount { mesh.triangle(hub, hub + 1 + i, hub + 2 + i) }
            return start ..< mesh.indices.count
        }
        let topRange = caps.contains(.top) ? endCap(v1) : mesh.indices.count ..< mesh.indices.count
        let bottomRange = caps.contains(.bottom) ? endCap(v0) : mesh.indices.count ..< mesh.indices.count

        // Interior caps: the planes a partial sweep leaves open, each the profile at that u closed by the axis (or,
        // for a torus, the tube's cross-section), fanned from its middle.
        let interiorStart = mesh.indices.count
        if caps.contains(.interior), !isCircleComplete, kind != .disk {
            for u in [u0, u1] {
                var outline: [SIMD3<Float>] = (0...vCount).map { point(u, v0 + (v1 - v0) * Float($0) / Float(vCount)) }
                if let top = axisPoint(v1), let bottom = axisPoint(v0) {
                    outline += [top, bottom]
                }
                let center = outline.reduce(SIMD3<Float>.zero, +) / Float(outline.count)
                // Newell's normal of the outline, turned away from the solid.
                var normal = SIMD3<Float>.zero
                for k in outline.indices {
                    let p = outline[k] - center, q = outline[(k + 1) % outline.count] - center
                    normal += p.cross(q)
                }
                normal = normal.normalized
                if normal.dot(center - inside) < 0 { normal = -normal }
                let hub = mesh.count
                mesh.vertex(center, normal, SIMD2(0.5, 0.5))
                for p in outline { mesh.vertex(p, normal, SIMD2(0.5, 0.5)) }
                for k in outline.indices { mesh.triangle(hub, hub + 1 + k, hub + 1 + (k + 1) % outline.count) }
            }
        }
        let interiorRange = interiorStart ..< mesh.indices.count

        return mesh.build(submeshes: [
            Submesh(range: faceRange, materialIndex: Part.face.rawValue),
            Submesh(range: topRange, materialIndex: Part.topCap.rawValue),
            Submesh(range: bottomRange, materialIndex: Part.bottomCap.rawValue),
            Submesh(range: interiorRange, materialIndex: Part.interiorCap.rawValue),
        ])
    }
}

/// Gathers an indexed mesh, winding each triangle to face the way its vertices' normals do and leaving out ones
/// with no area, as at a pole.
struct MeshAccumulator {

    private(set) var positions: [SIMD3<Float>] = []
    private(set) var normals: [SIMD3<Float>] = []
    private(set) var textureCoordinates: [SIMD2<Float>] = []
    private(set) var indices: [Int] = []

    var count: Int { positions.count }

    mutating func vertex(_ p: SIMD3<Float>, _ n: SIMD3<Float>, _ uv: SIMD2<Float>) {
        positions.append(p)
        normals.append(n)
        textureCoordinates.append(uv)
    }

    mutating func triangle(_ a: Int, _ b: Int, _ c: Int) {
        let face = (positions[b] - positions[a]).cross(positions[c] - positions[a])
        guard face.lengthSquared > 1e-14 else { return }
        if face.dot(normals[a] + normals[b] + normals[c]) < 0 {
            indices += [a, c, b]
        } else {
            indices += [a, b, c]
        }
    }

    func build(submeshes: [Submesh]) -> MeshBuffer {
        MeshBuffer(
            vertexCount: positions.count,
            streams: [
                VertexStream(semantic: .position, vectors: positions),
                VertexStream(semantic: .normal, vectors: normals),
                VertexStream(semantic: .textureCoordinate(0), vectors: textureCoordinates),
            ],
            indices: IndexBuffer(indices),
            submeshes: submeshes
        )
    }
}
