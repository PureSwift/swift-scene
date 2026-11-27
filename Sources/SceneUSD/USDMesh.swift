import SceneCore
import SceneFormats

enum USDMesh {
    static func make(_ prim: USDPrim) throws(SceneFormatError) -> MeshBuffer {
        let scheme = try USDRead.attribute(prim, "subdivisionScheme", types: ["token"]) ?? .string("catmullClark")
        guard try USDRead.string(scheme) == "none" else { throw .unsupported("USD subdivision surfaces") }
        guard let pointValue = try USDRead.attribute(prim, "points", types: ["point3f[]"]),
              let countValue = try USDRead.attribute(prim, "faceVertexCounts", types: ["int[]"]),
              let indexValue = try USDRead.attribute(prim, "faceVertexIndices", types: ["int[]"]) else {
            throw USDRead.invalid("Missing USD mesh topology")
        }
        var points: [SIMD3<Float>] = []
        for point in try USDRead.array(pointValue) {
            let v = try USDRead.tuple(point, count: 3)
            points.append(SIMD3(v[0], v[1], v[2]))
        }
        let counts = try USDRead.integers(countValue)
        let indices = try USDRead.integers(indexValue)
        var total = 0
        for count in counts {
            guard count >= 3, count <= indices.count - total else { throw USDRead.invalid("Invalid USD face vertex count") }
            total += count
        }
        guard total == indices.count, indices.allSatisfy({ points.indices.contains($0) }) else {
            throw USDRead.invalid("Invalid USD face vertex indices")
        }
        let holes = try USDRead.integers(USDRead.attribute(prim, "holeIndices", types: ["int[]"]) ?? .array([]))
        guard holes.allSatisfy({ counts.indices.contains($0) }), Set(holes).count == holes.count else {
            throw USDRead.invalid("Invalid USD hole indices")
        }
        let holeSet = Set(holes)
        let orientation = try USDRead.string(USDRead.attribute(prim, "orientation", types: ["token"]) ?? .string("rightHanded"))
        guard ["rightHanded", "leftHanded"].contains(orientation) else { throw USDRead.invalid("Invalid USD orientation") }
        let leftHanded = orientation == "leftHanded"
        let normals = try samples(prim, name: "normals", types: ["normal3f[]"], width: 3,
                                  fallback: "vertex", points: points.count, faces: counts.count, corners: total)
        let uv = try samples(prim, name: "primvars:st", types: ["texCoord2f[]", "float2[]"], width: 2,
                             fallback: "constant", points: points.count, faces: counts.count, corners: total)
        var positions: [SIMD3<Float>] = []
        var normalData: [Float] = []
        var uvData: [Float] = []
        var offset = 0
        for (face, count) in counts.enumerated() {
            defer { offset += count }
            guard !holeSet.contains(face) else { continue }
            let polygon = (0..<count).map { points[indices[offset + $0]] }
            let triangles = Triangulation.triangulate([polygon])
            guard triangles.count == count - 2 else { throw USDRead.invalid("Degenerate USD polygon") }
            let faceNormal = Triangulation.newellNormal(polygon) * (leftHanded ? -1 : 1)
            for triangle in triangles {
                let corners = leftHanded ? [triangle.x, triangle.z, triangle.y] : [triangle.x, triangle.y, triangle.z]
                for corner in corners {
                    let vertex = indices[offset + corner]
                    positions.append(points[vertex])
                    if let normals {
                        normalData += normals.sample(point: vertex, face: face, corner: offset + corner)
                    } else { normalData += [faceNormal.x, faceNormal.y, faceNormal.z] }
                    if let uv {
                        let value = uv.sample(point: vertex, face: face, corner: offset + corner)
                        // USD st is bottom-origin; SceneFormats' texture streams are top-origin.
                        uvData += [value[0], 1 - value[1]]
                    }
                }
            }
        }
        var streams = [VertexStream(semantic: .position, vectors: positions),
                       VertexStream(semantic: .normal, componentCount: 3, data: normalData)]
        if uv != nil { streams.append(VertexStream(semantic: .textureCoordinate(0), componentCount: 2, data: uvData)) }
        return MeshBuffer(vertexCount: positions.count, streams: streams,
                          submeshes: positions.isEmpty ? [] : [Submesh(range: 0..<positions.count, materialIndex: 0)])
    }

    private struct Samples {
        let values: [[Float]]
        let indices: [Int]?
        let interpolation: String

        func sample(point: Int, face: Int, corner: Int) -> [Float] {
            let slot: Int
            switch interpolation {
            case "constant": slot = 0
            case "uniform": slot = face
            case "faceVarying": slot = corner
            default: slot = point
            }
            return values[indices?[slot] ?? slot]
        }
    }

    private static func samples(_ prim: USDPrim, name: String, types: [String], width: Int, fallback: String,
                                points: Int, faces: Int, corners: Int) throws(SceneFormatError) -> Samples? {
        guard let value = try USDRead.attribute(prim, name, types: types) else {
            if prim[property: name + ":indices"] != nil { throw USDRead.invalid("USD primvar indices without values") }
            return nil
        }
        let metadata = prim[property: name]?.metadata ?? [:]
        let interpolation = try USDRead.string(metadata["interpolation"] ?? .string(fallback))
        let expected: Int
        switch interpolation {
        case "constant": expected = 1
        case "uniform": expected = faces
        case "vertex", "varying": expected = points
        case "faceVarying": expected = corners
        default: throw .unsupported("USD interpolation \(interpolation)")
        }
        if let size = metadata["elementSize"], size != .number("1") { throw .unsupported("USD primvar elementSize") }
        if metadata["unauthoredValuesIndex"] != nil { throw .unsupported("USD unauthored primvar values") }
        var values: [[Float]] = []
        for value in try USDRead.array(value) { values.append(try USDRead.tuple(value, count: width)) }
        let indices: [Int]?
        if let value = try USDRead.attribute(prim, name + ":indices", types: ["int[]"]) {
            let parsed = try USDRead.integers(value)
            guard parsed.count == expected, parsed.allSatisfy({ values.indices.contains($0) }) else {
                throw USDRead.invalid("Invalid USD primvar indices")
            }
            indices = parsed
        } else {
            guard values.count == expected else { throw USDRead.invalid("USD interpolation value count mismatch") }
            indices = nil
        }
        return Samples(values: values, indices: indices, interpolation: interpolation)
    }
}
