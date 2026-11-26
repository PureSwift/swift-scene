// Ported from Quesa's 3DMF readers for polygonal geometry (E3FFR_3DMF_Geometry.cpp, E3FFR_3DMF.cpp).
// Copyright (c) 1999-2021, Quesa Developers. All rights reserved.
// Licensed under the BSD 3-Clause License; see LICENSE-Quesa.

import SceneCore

/// Gathers polygonal faces — each one or more contours of vertices with attributes of their own — into a mesh,
/// as Polygon, GeneralPolygon, Mesh and TriGrid are drawn.
struct PolygonMeshBuilder {

    struct Vertex {
        var position: SIMD3<Float>
        var attributes = ThreeDMFDecoder.Attributes()
    }

    private var positions: [SIMD3<Float>] = []
    private var normals: [SIMD3<Float>] = []
    private var uvs: [SIMD2<Float>?] = []
    /// Each vertex's own colour and alpha, when it or its face has them.
    private var colors: [(rgb: SIMD3<Float>?, alpha: Float?)] = []
    private var indices: [Int] = []

    /// Adds a face: contours by the even-odd rule, its front the side its first contour winds counter-clockwise
    /// about. A vertex's normal is its own, or the face's, or the face's shape's.
    mutating func addFace(_ contours: [[Vertex]], attributes face: ThreeDMFDecoder.Attributes = .init()) {
        let flat = contours.flatMap { $0 }
        guard flat.count >= 3, let first = contours.first(where: { $0.count >= 3 }) else { return }
        let shapeNormal = Triangulation.newellNormal(first.map(\.position))
        guard shapeNormal.lengthSquared > 0 else { return }
        let triangles = Triangulation.triangulate(contours.map { $0.map(\.position) }, normal: shapeNormal)
        guard !triangles.isEmpty else { return }
        let faceNormal = face.normal?.normalized ?? shapeNormal
        let base = positions.count
        for vertex in flat {
            positions.append(vertex.position)
            normals.append(vertex.attributes.normal?.normalized ?? faceNormal)
            uvs.append(vertex.attributes.uv)
            let transparency = vertex.attributes.transparency ?? face.transparency
            colors.append((vertex.attributes.diffuse ?? face.diffuse, transparency.map { ($0.x + $0.y + $0.z) / 3 }))
        }
        for t in triangles {
            indices += [base + t.x, base + t.y, base + t.z]
        }
    }

    var isEmpty: Bool { indices.isEmpty }

    /// Whether any vertex or face had its own colour or transparency.
    var hasColors: Bool { colors.contains { $0.rgb != nil || $0.alpha != nil } }

    /// The mesh. Vertices without a colour of their own take `defaultColor`, the geometry's.
    func build(defaultColor: SIMD3<Float>) -> MeshBuffer {
        var streams = [
            VertexStream(semantic: .position, vectors: positions),
            VertexStream(semantic: .normal, vectors: normals),
        ]
        if uvs.contains(where: { $0 != nil }) {
            // QuickDraw 3D's v runs up; ours down.
            streams.append(VertexStream(semantic: .textureCoordinate(0), vectors: uvs.map { uv in
                uv.map { SIMD2($0.x, 1 - $0.y) } ?? .zero
            }))
        }
        if hasColors {
            streams.append(VertexStream(semantic: .color, vectors: colors.map { SIMD4($0.rgb ?? defaultColor, $0.alpha ?? 1) }))
        }
        return MeshBuffer(
            vertexCount: positions.count,
            streams: streams,
            indices: IndexBuffer(indices),
            submeshes: [Submesh(range: 0 ..< indices.count, materialIndex: 0)]
        )
    }
}

// MARK: - Attribute set lists

extension ThreeDMFDecoder {

    /// An attribute set list's sets, one slot for each vertex or face: a count; `Include` or `Exclude`; indices;
    /// then the sets, as children, for the indices included, or for all but those excluded. No indices with
    /// `Exclude`, or every index with `Include`, fills every slot in order.
    func attributeSetList(_ list: MetafileObject) throws(SceneFormatError) -> [Attributes?] {
        var r = list.reader()
        let count = Int(try r.uint32())
        guard count > 0, count < 1 << 24 else { return [] }
        let exclude = try r.enumerated(["include": 0, "exclude": 1]) == 1
        let indexCount = Int(try r.uint32())
        guard indexCount <= count else { throw .malformed("\(indexCount) indices for \(count) attribute sets", offset: nil) }
        var indices: [Int] = []
        for _ in 0..<indexCount { indices.append(Int(try r.uint32())) }
        let slots: [Int]
        if (exclude && indexCount == 0) || (!exclude && indexCount == count) {
            slots = Array(0..<count)
        } else if exclude {
            let skipped = Set(indices)
            slots = (0..<count).filter { !skipped.contains($0) }
        } else {
            slots = indices
        }
        var sets = [Attributes?](repeating: nil, count: count)
        for (slot, set) in zip(slots, list.children.filter { $0.type == .attributeSet }) where slot < count {
            sets[slot] = try attributes(set)
        }
        return sets
    }

    /// The sets of the first list of the type among an object's children; empty when there is none.
    func attributeSetList(_ type: MetafileObjectType, in object: MetafileObject) throws(SceneFormatError) -> [Attributes?] {
        guard let list = object.children.first(where: { $0.type == type }) else { return [] }
        return try attributeSetList(list)
    }
}
