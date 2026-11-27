import SceneCore
import SceneFormats
import SceneGraph

/// Exports the current visible scene pose as standalone USDA or a USDZ containing scene.usda.
/// Animation, physics and backgrounds are not serialized. Shading networks are not yet supported.
public struct USDSceneEncoder: SceneAssetEncoder {
    public enum Encoding: Hashable, Sendable { case usda, usdz }
    public static let fileExtensions = ["usda", "usd", "usdz"]
    public var encoding: Encoding
    /// Explicitly discard materials, cameras, lights and opacity. Geometry keeps normals and UV0.
    public var geometryOnly: Bool

    public init(encoding: Encoding = .usda, geometryOnly: Bool = false) {
        self.encoding = encoding
        self.geometryOnly = geometryOnly
    }

    public func encode(_ scene: Scene) async throws(SceneFormatError) -> [UInt8] {
        try encodeScene(scene)
    }

    public func encodeScene(_ scene: Scene) throws(SceneFormatError) -> [UInt8] {
        var writer = USDSceneWriter(geometryOnly: geometryOnly)
        writer.lines = ["#usda 1.0", "(", "    defaultPrim = \"Scene\"", "    metersPerUnit = 1", "    upAxis = \"Y\"", ")", ""]
        // Always author a valid default prim, including for an empty or entirely hidden scene.
        writer.line("def Xform \"Scene\"", depth: 0)
        writer.line("{", depth: 0)
        try writer.node(scene.rootNode, identifier: "Root", depth: 1)
        writer.line("}", depth: 0)
        let bytes = Array((writer.lines.joined(separator: "\n") + "\n").utf8)
        switch encoding {
        case .usda: return bytes
        case .usdz: return try USDZArchive(entries: [.init(path: "scene.usda", data: bytes)]).encoded()
        }
    }

    /// Per-conversion registrations; .usd deliberately contains USDA text, never Crate bytes.
    public var fileEncoders: [String: SceneAssetConverter.Encoder] {
        let text = USDSceneEncoder(encoding: .usda, geometryOnly: geometryOnly)
        let package = USDSceneEncoder(encoding: .usdz, geometryOnly: geometryOnly)
        return ["usda": text.encodeScene, "usd": text.encodeScene, "usdz": package.encodeScene]
    }
}

private struct USDSceneWriter {
    let geometryOnly: Bool
    var lines: [String] = []

    mutating func line(_ text: String, depth: Int) { lines.append(String(repeating: "    ", count: depth) + text) }

    mutating func node(_ node: Node, identifier: String, depth: Int) throws(SceneFormatError) {
        guard !node.isHidden else { return }
        // Leaves room for mesh tuples within the reader's combined nesting limit.
        guard depth < 26 else { throw .unsupported("USD export hierarchy exceeds 25 node levels") }
        guard node.opacity.isFinite, (0...1).contains(node.opacity) else { throw USDRead.invalid("Invalid node opacity") }
        if !geometryOnly, node.camera != nil || node.light != nil || node.opacity != 1 {
            throw .unsupported("USD export of cameras, lights or opacity; opt into geometryOnly")
        }
        let matrix = node.transform
        guard matrix.columnMajorElements.allSatisfy({ $0.isFinite }),
              matrix[3,0] == 0, matrix[3,1] == 0, matrix[3,2] == 0, matrix[3,3] == 1 else {
            throw USDRead.invalid("USD export requires a finite affine transform")
        }
        line("def Xform \"\(identifier)\" (", depth: depth)
        if let name = node.name { line("displayName = \(try quoted(name))", depth: depth + 1) }
        line(")", depth: depth)
        line("{", depth: depth)
        // Engine columns are USD rows because USD matrices act on row vectors.
        let rows = (0..<4).map { c in tuple((0..<4).map { matrix[$0,c] }) }
        line("matrix4d xformOp:transform = (\(rows.joined(separator: ", ")))", depth: depth + 1)
        line("uniform token[] xformOpOrder = [\"xformOp:transform\"]", depth: depth + 1)
        if let geometry = node.geometry { try mesh(geometry, depth: depth + 1) }
        for (index, child) in node.children.enumerated() {
            // Stable IDs avoid collisions with arbitrary Unicode/user-supplied names and generated meshes.
            try self.node(child, identifier: "Node_\(index)", depth: depth + 1)
        }
        line("}", depth: depth)
    }

    mutating func mesh(_ geometry: Geometry, depth: Int) throws(SceneFormatError) {
        let mesh = geometry.mesh
        guard mesh.vertexCount >= 0, mesh.vertexCount <= Int(Int32.max) else { throw USDRead.invalid("Invalid USD vertex count") }
        if mesh.vertexCount == 0 {
            guard mesh.streams.allSatisfy({ $0.data.isEmpty }), (mesh.indices?.count ?? 0) == 0,
                  mesh.submeshes.allSatisfy({ $0.range.isEmpty }) else { throw USDRead.invalid("Invalid empty mesh") }
            return
        }
        var semantics: Set<VertexSemantic> = []
        for stream in mesh.streams {
            guard stream.componentCount > 0, stream.data.count % stream.componentCount == 0,
                  stream.data.count / stream.componentCount == mesh.vertexCount,
                  stream.data.allSatisfy({ $0.isFinite }), semantics.insert(stream.semantic).inserted else {
                throw USDRead.invalid("Invalid USD vertex stream")
            }
            switch stream.semantic {
            case .position, .normal:
                guard stream.componentCount == 3 else { throw USDRead.invalid("USD positions/normals require three components") }
            case .textureCoordinate(0):
                guard stream.componentCount == 2 else { throw USDRead.invalid("USD UV0 requires two components") }
            case .jointIndices, .jointWeights: break // The current deformed mesh is the static snapshot.
            default:
                guard geometryOnly else { throw .unsupported("USD vertex semantic \(stream.semantic); opt into geometryOnly") }
            }
        }
        guard semantics.contains(.position) else { throw USDRead.invalid("USD mesh requires positions") }
        let positions = mesh.positions
        let count = mesh.indices?.count ?? mesh.vertexCount
        // Match renderer behavior: no submeshes means no draw calls.
        for (submeshIndex, submesh) in mesh.submeshes.enumerated() {
            guard submesh.range.lowerBound >= 0, submesh.range.upperBound <= count, submesh.materialIndex >= 0 else {
                throw USDRead.invalid("Invalid USD submesh range or material index")
            }
            guard submesh.primitive == .triangles || submesh.primitive == .triangleStrip else {
                throw .unsupported("USD export requires triangle meshes")
            }
            if submesh.range.isEmpty { continue }
            guard submesh.range.count >= 3, submesh.primitive != .triangles || submesh.range.count % 3 == 0 else {
                throw USDRead.invalid("Incomplete USD triangle primitive")
            }
            for i in submesh.range {
                guard (0..<mesh.vertexCount).contains(mesh.vertex(at: i)) else { throw USDRead.invalid("USD mesh index out of range") }
            }
            let material = geometry.material(forSubmesh: submeshIndex).descriptor
            var comparable = material
            comparable.name = nil
            comparable.isDoubleSided = false
            if !geometryOnly, comparable != .default {
                throw .unsupported("USD material export is not implemented; opt into geometryOnly")
            }
            var faces: [SIMD3<Int>] = []
            for triangle in mesh.triangles(in: submesh) {
                if triangle.x == triangle.y || triangle.y == triangle.z || triangle.z == triangle.x { continue }
                let normal = (positions[triangle.y] - positions[triangle.x]).cross(positions[triangle.z] - positions[triangle.x])
                guard normal.x.isFinite, normal.y.isFinite, normal.z.isFinite else { throw USDRead.invalid("USD triangle arithmetic overflow") }
                if normal.lengthSquared == 0 { continue }
                faces.append(triangle)
            }
            if faces.isEmpty { continue }
            line("def Mesh \"Mesh_\(submeshIndex)\" (", depth: depth)
            if let name = submesh.name ?? geometry.name { line("displayName = \(try quoted(name))", depth: depth + 1) }
            line(")", depth: depth)
            line("{", depth: depth)
            let indent = depth + 1
            line("uniform token subdivisionScheme = \"none\"", depth: indent)
            line("uniform token orientation = \"rightHanded\"", depth: indent)
            line("bool doubleSided = \(material.isDoubleSided ? "true" : "false")", depth: indent)
            line("point3f[] points = [\(positions.map { tuple([$0.x, $0.y, $0.z]) }.joined(separator: ", "))]", depth: indent)
            line("int[] faceVertexCounts = [\(Array(repeating: "3", count: faces.count).joined(separator: ", "))]", depth: indent)
            line("int[] faceVertexIndices = [\(faces.flatMap { [String($0.x), String($0.y), String($0.z)] }.joined(separator: ", "))]", depth: indent)
            if let normals = mesh.stream(.normal) {
                let values = stride(from: 0, to: normals.data.count, by: 3).map { tuple(Array(normals.data[$0..<$0+3])) }
                line("normal3f[] normals = [\(values.joined(separator: ", "))] (interpolation = \"vertex\")", depth: indent)
            }
            if let uv = mesh.stream(.textureCoordinate(0)) {
                let values = stride(from: 0, to: uv.data.count, by: 2).map { tuple([uv.data[$0], 1 - uv.data[$0+1]]) }
                line("texCoord2f[] primvars:st = [\(values.joined(separator: ", "))] (interpolation = \"vertex\")", depth: indent)
            }
            line("}", depth: depth)
        }
    }

    private func tuple(_ values: [Float]) -> String { "(" + values.map { String($0) }.joined(separator: ", ") + ")" }

    private func quoted(_ value: String) throws(SceneFormatError) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 34: result += "\\\""
            case 92: result += "\\\\"
            case 10: result += "\\n"
            case 13: result += "\\r"
            case 9: result += "\\t"
            case 0..<32, 127: throw .unsupported("Control character in USD display name")
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}
