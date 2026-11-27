import SceneCore
import SceneFormats
import SceneGraph

/// Exports the current visible scene pose as standalone USDA or a USDZ containing scene.usda.
/// Animation, physics and backgrounds are not serialized. Exports Preview Surface constants and packaged diffuse and emissive textures.
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
        var writer = USDSceneWriter(geometryOnly: geometryOnly, packagesTextures: encoding == .usdz)
        writer.lines = ["#usda 1.0", "(", "    defaultPrim = \"Scene\"", "    metersPerUnit = 1", "    upAxis = \"Y\"", ")", ""]
        // Always author a valid default prim, including for an empty or entirely hidden scene.
        writer.line("def Xform \"Scene\"", depth: 0)
        writer.line("{", depth: 0)
        try writer.node(scene.rootNode, identifier: "Root", parentPath: "/Scene", depth: 1)
        writer.line("}", depth: 0)
        let bytes = Array((writer.lines.joined(separator: "\n") + "\n").utf8)
        switch encoding {
        case .usda: return bytes
        case .usdz: return try USDZArchive(entries: [.init(path: "scene.usda", data: bytes)] + writer.textures).encoded()
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
    let packagesTextures: Bool
    var lines: [String] = []
    var textures: [USDZArchive.Entry] = []
    var imagePaths: [ImageBuffer: String] = [:]

    mutating func line(_ text: String, depth: Int) { lines.append(String(repeating: "    ", count: depth) + text) }

    mutating func node(_ node: Node, identifier: String, parentPath: String, depth: Int) throws(SceneFormatError) {
        guard !node.isHidden else { return }
        // Leaves room for mesh tuples within the reader's combined nesting limit.
        guard depth < 26 else { throw .unsupported("USD export hierarchy exceeds 25 node levels") }
        guard node.opacity.isFinite, (0...1).contains(node.opacity) else { throw USDRead.invalid("Invalid node opacity") }
        if !geometryOnly, node.camera != nil || node.light != nil || node.opacity != 1 {
            throw .unsupported("USD export of cameras, lights or opacity; opt into geometryOnly")
        }
        let path = parentPath + "/" + identifier
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
        if let geometry = node.geometry { try mesh(geometry, parentPath: path, depth: depth + 1) }
        for (index, child) in node.children.enumerated() {
            // Stable IDs avoid collisions with arbitrary Unicode/user-supplied names and generated meshes.
            try self.node(child, identifier: "Node_\(index)", parentPath: path, depth: depth + 1)
        }
        line("}", depth: depth)
    }

    mutating func mesh(_ geometry: Geometry, parentPath: String, depth: Int) throws(SceneFormatError) {
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
            var constants = material
            var texture: USDTextureExport?
            if !geometryOnly, case .texture = material.diffuse.contents {
                guard packagesTextures else { throw .unsupported("Textured USD export requires .usdz output") }
                guard material.lightingModel != .unlit else { throw .unsupported("USDZ unlit texture export") }
                guard mesh.stream(.textureCoordinate(0)) != nil else { throw USDRead.invalid("USDZ textured mesh requires UV0") }
                texture = try USDTextureExport(material.diffuse)
                constants.diffuse = .color(SIMD4(repeating: 1))
            }
            var emissionTexture: USDTextureExport?
            if !geometryOnly, case .texture = material.emission.contents {
                guard packagesTextures else { throw .unsupported("Textured USD export requires .usdz output") }
                guard material.lightingModel != .unlit else { throw .unsupported("USDZ unlit texture export") }
                guard mesh.stream(.textureCoordinate(0)) != nil else { throw USDRead.invalid("USDZ textured mesh requires UV0") }
                emissionTexture = try USDTextureExport(material.emission)
                constants.emission = .color(SIMD4(repeating: 1))
            }
            var packedTexture: USDTextureExport?
            if !geometryOnly, case .texture = material.metalness.contents {
                guard packagesTextures else { throw .unsupported("Textured USD export requires .usdz output") }
                guard material.lightingModel == .physicallyBased, material.metalness == material.roughness else {
                    throw .unsupported("USDZ requires a shared packed metallic-roughness texture on a PBR material")
                }
                guard mesh.stream(.textureCoordinate(0)) != nil else { throw USDRead.invalid("USDZ textured mesh requires UV0") }
                packedTexture = try USDTextureExport(material.metalness)
                constants.metalness = .scalar(1)
                constants.roughness = .scalar(1)
            }
            var normalTexture: USDTextureExport?
            let normalStrength = material.normal.intensity
            if !geometryOnly, case .texture = material.normal.contents {
                guard packagesTextures else { throw .unsupported("Textured USD export requires .usdz output") }
                guard material.lightingModel != .unlit else { throw .unsupported("USDZ unlit normal maps") }
                guard mesh.stream(.textureCoordinate(0)) != nil else { throw USDRead.invalid("USDZ normal map requires UV0") }
                guard normalStrength >= 0, (normalStrength * 2).isFinite else { throw USDRead.invalid("Invalid normal strength") }
                var property = material.normal
                property.intensity = 1
                normalTexture = try USDTextureExport(property)
                constants.normal = MaterialProperty()
            }
            var occlusionTexture: USDTextureExport?
            let occlusionStrength = material.ambientOcclusion.intensity
            if !geometryOnly, case .texture = material.ambientOcclusion.contents {
                guard packagesTextures else { throw .unsupported("Textured USD export requires .usdz output") }
                guard material.lightingModel != .unlit else { throw .unsupported("USDZ unlit occlusion maps") }
                guard mesh.stream(.textureCoordinate(0)) != nil else { throw USDRead.invalid("USDZ occlusion map requires UV0") }
                guard occlusionStrength.isFinite, (0...1).contains(occlusionStrength) else { throw USDRead.invalid("Invalid occlusion strength") }
                var property = material.ambientOcclusion
                property.intensity = 1
                occlusionTexture = try USDTextureExport(property)
                constants.ambientOcclusion = MaterialProperty()
            }
            let preview = !geometryOnly && comparable != .default ? try USDPreviewMaterial(constants) : nil
            let materialPath = parentPath + "/Mesh_\(submeshIndex)/Material"
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
            if preview != nil { line("apiSchemas = [\"MaterialBindingAPI\"]", depth: depth + 1) }
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
            if let preview {
                line("rel material:binding = <\(materialPath)>", depth: indent)
                line("def Material \"Material\" (", depth: indent)
                if let name = material.name { line("displayName = \(try quoted(name))", depth: indent + 1) }
                line(")", depth: indent)
                line("{", depth: indent)
                line("token outputs:surface.connect = <\(materialPath)/Shader.outputs:surface>", depth: indent + 1)
                line("def Shader \"Shader\"", depth: indent + 1)
                line("{", depth: indent + 1)
                let shaderDepth = indent + 2
                line("uniform token info:id = \"UsdPreviewSurface\"", depth: shaderDepth)
                if texture != nil {
                    line("color3f inputs:diffuseColor.connect = <\(materialPath)/DiffuseTexture.outputs:rgb>", depth: shaderDepth)
                } else {
                    line("color3f inputs:diffuseColor = \(tuple([preview.diffuse.x, preview.diffuse.y, preview.diffuse.z]))", depth: shaderDepth)
                }
                if emissionTexture != nil {
                    line("color3f inputs:emissiveColor.connect = <\(materialPath)/EmissionTexture.outputs:rgb>", depth: shaderDepth)
                } else {
                    line("color3f inputs:emissiveColor = \(tuple([preview.emission.x, preview.emission.y, preview.emission.z]))", depth: shaderDepth)
                }
                if packedTexture != nil {
                    line("float inputs:metallic.connect = <\(materialPath)/MetallicRoughnessTexture.outputs:b>", depth: shaderDepth)
                    line("float inputs:roughness.connect = <\(materialPath)/MetallicRoughnessTexture.outputs:g>", depth: shaderDepth)
                } else {
                    line("float inputs:metallic = \(preview.metallic)", depth: shaderDepth)
                    line("float inputs:roughness = \(preview.roughness)", depth: shaderDepth)
                }
                if texture != nil, material.alphaMode != .opaque {
                    line("float inputs:opacity.connect = <\(materialPath)/DiffuseTexture.outputs:a>", depth: shaderDepth)
                } else {
                    line("float inputs:opacity = \(preview.opacity)", depth: shaderDepth)
                }
                line("float inputs:opacityThreshold = \(preview.opacityThreshold)", depth: shaderDepth)
                if normalTexture != nil {
                    line("normal3f inputs:normal.connect = <\(materialPath)/NormalTexture.outputs:rgb>", depth: shaderDepth)
                }
                if occlusionTexture != nil {
                    line("float inputs:occlusion.connect = <\(materialPath)/OcclusionTexture.outputs:r>", depth: shaderDepth)
                }
                if material.lightingModel == .unlit { line("float inputs:ior = 1", depth: shaderDepth) }
                line("token outputs:surface", depth: shaderDepth)
                line("}", depth: indent + 1)
                if let texture {
                    try textureShaders(texture, name: "DiffuseTexture", scale: [preview.diffuse.x, preview.diffuse.y, preview.diffuse.z, preview.opacity],
                                       writeUVReader: true, materialPath: materialPath, depth: indent + 1)
                }
                if let emissionTexture {
                    try textureShaders(emissionTexture, name: "EmissionTexture", scale: [preview.emission.x, preview.emission.y, preview.emission.z, 1],
                                       writeUVReader: texture == nil, materialPath: materialPath, depth: indent + 1)
                }
                if let packedTexture {
                    try textureShaders(packedTexture, name: "MetallicRoughnessTexture", scale: [1, preview.roughness, preview.metallic, 1],
                                       writeUVReader: texture == nil && emissionTexture == nil, materialPath: materialPath,
                                       depth: indent + 1, colorSpace: "raw")
                }
                if let normalTexture {
                    // Flipping mesh V reverses the bitangent: negate tangent-space Y to preserve lighting.
                    try textureShaders(normalTexture, name: "NormalTexture", scale: [2 * normalStrength, -2 * normalStrength, 2, 1],
                                       writeUVReader: texture == nil && emissionTexture == nil && packedTexture == nil,
                                       materialPath: materialPath, depth: indent + 1, colorSpace: "raw",
                                       bias: [-normalStrength, normalStrength, -1, 0])
                }
                if let occlusionTexture {
                    // Match mix(1, red, strength) without altering shared ORM image pixels.
                    try textureShaders(occlusionTexture, name: "OcclusionTexture", scale: [occlusionStrength, 1, 1, 1],
                                       writeUVReader: texture == nil && emissionTexture == nil && packedTexture == nil && normalTexture == nil,
                                       materialPath: materialPath, depth: indent + 1, colorSpace: "raw",
                                       bias: [1 - occlusionStrength, 0, 0, 0])
                }
                line("}", depth: indent)
            }
            line("}", depth: depth)
        }
    }

    private mutating func textureShaders(_ texture: USDTextureExport, name: String, scale: [Float],
                                         writeUVReader: Bool, materialPath: String, depth: Int, colorSpace: String = "sRGB", bias: [Float]? = nil) throws(SceneFormatError) {
        let path: String
        if let existing = imagePaths[texture.image] { path = existing }
        else {
            path = "textures/diffuse_\(textures.count).png"
            let bytes = try PNGEncoder.encode(texture.image)
            textures.append(.init(path: path, data: bytes))
            imagePaths[texture.image] = path
        }
        if writeUVReader {
            line("def Shader \"UVReader\"", depth: depth)
            line("{", depth: depth)
            line("uniform token info:id = \"UsdPrimvarReader_float2\"", depth: depth + 1)
            line("string inputs:varname = \"st\"", depth: depth + 1)
            line("float2 outputs:result", depth: depth + 1)
            line("}", depth: depth)
        }
        line("def Shader \"\(name)\"", depth: depth)
        line("{", depth: depth)
        line("uniform token info:id = \"UsdUVTexture\"", depth: depth + 1)
        line("asset inputs:file = @\(path)@", depth: depth + 1)
        line("token inputs:sourceColorSpace = \"\(colorSpace)\"", depth: depth + 1)
        line("float2 inputs:st.connect = <\(materialPath)/UVReader.outputs:result>", depth: depth + 1)
        line("token inputs:wrapS = \"\(texture.wrapS)\"", depth: depth + 1)
        line("token inputs:wrapT = \"\(texture.wrapT)\"", depth: depth + 1)
        line("float4 inputs:scale = \(tuple(scale))", depth: depth + 1)
        if let bias { line("float4 inputs:bias = \(tuple(bias))", depth: depth + 1) }
        line("float3 outputs:rgb", depth: depth + 1)
        line("float outputs:a", depth: depth + 1)
        if colorSpace == "raw" {
            line("float outputs:r", depth: depth + 1)
            line("float outputs:g", depth: depth + 1)
            line("float outputs:b", depth: depth + 1)
        }
        line("}", depth: depth)
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
