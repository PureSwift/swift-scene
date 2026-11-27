import Foundation
import SceneCore
import SceneGraph

/// Exports the current visible mesh pose as a self-contained glTF 2.0 binary file.
/// Animation, physics and scene backgrounds are not serialized. Legacy lighting models are
/// approximated as nonmetallic PBR surfaces. Supports cameras and punctual lights.
public struct GLBEncoder: SceneAssetEncoder {
    public static let fileExtensions = ["glb"]
    public var omitCamerasAndLights: Bool
    /// Viewport width/height for horizontal-FOV or orthographic cameras without a fixed aspect.
    public var cameraAspectRatio: Float?

    public init(omitCamerasAndLights: Bool = false, cameraAspectRatio: Float? = nil) {
        self.omitCamerasAndLights = omitCamerasAndLights
        self.cameraAspectRatio = cameraAspectRatio
    }

    public func encode(_ scene: Scene) async throws(SceneFormatError) -> [UInt8] {
        try encodeScene(scene)
    }

    public func encodeScene(_ scene: Scene) throws(SceneFormatError) -> [UInt8] {
        var writer = GLBWriter(omitCamerasAndLights: omitCamerasAndLights, cameraAspectRatio: cameraAspectRatio)
        return try writer.encode(scene)
    }
}

private struct GLBWriter {
    let omitCamerasAndLights: Bool
    let cameraAspectRatio: Float?
    var cameras: [[String: Any]] = []
    var lights: [[String: Any]] = []
    var binary: [UInt8] = []
    var views: [[String: Any]] = []
    var accessors: [[String: Any]] = []
    var nodes: [[String: Any]] = []
    var meshes: [[String: Any]] = []
    var materials: [[String: Any]] = []
    var images: [[String: Any]] = []
    var textures: [[String: Any]] = []
    var samplers: [[String: Any]] = []
    var usesUnlit = false

    mutating func encode(_ scene: Scene) throws(SceneFormatError) -> [UInt8] {
        let root = try node(scene.rootNode, opacity: 1, depth: 0)
        let sceneDefinition: [String: Any] = root.map { ["nodes": [$0]] } ?? [:]
        var document: [String: Any] = ["asset": ["version": "2.0", "generator": "swift-scene"],
            "scene": 0, "scenes": [sceneDefinition]]
        for (key, values) in [("nodes", nodes), ("meshes", meshes), ("materials", materials),
                              ("bufferViews", views), ("accessors", accessors), ("images", images),
                              ("textures", textures), ("samplers", samplers), ("cameras", cameras)] where !values.isEmpty {
            document[key] = values
        }
        var extensionsUsed: [String] = []
        if usesUnlit { extensionsUsed.append("KHR_materials_unlit") }
        if !lights.isEmpty {
            extensionsUsed.append("KHR_lights_punctual")
            document["extensions"] = ["KHR_lights_punctual": ["lights": lights]]
        }
        if !extensionsUsed.isEmpty { document["extensionsUsed"] = extensionsUsed }
        if !binary.isEmpty { document["buffers"] = [["byteLength": binary.count]] }
        var json: [UInt8]
        do { json = Array(try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])) }
        catch { throw .malformed("Cannot serialize glTF JSON: \(error)", offset: nil) }
        while json.count % 4 != 0 { json.append(32) }
        while binary.count % 4 != 0 { binary.append(0) }
        let length = 20 + json.count + (binary.isEmpty ? 0 : 8 + binary.count)
        guard length <= Int(UInt32.max) else { throw .unsupported("GLB exceeds 4 GB") }
        var output = words([0x46546c67, 2, UInt32(length), UInt32(json.count), 0x4e4f534a]) + json
        if !binary.isEmpty { output += words([UInt32(binary.count), 0x004e4942]) + binary }
        return output
    }

    mutating func node(_ node: Node, opacity: Float, depth: Int) throws(SceneFormatError) -> Int? {
        guard depth < 250 else { throw .unsupported("GLB hierarchy exceeds 250 levels") }
        if node.isHidden { return nil }
        let opacity = opacity * node.opacity
        guard opacity.isFinite, (0...1).contains(opacity), node.transform.columnMajorElements.allSatisfy(\.isFinite) else {
            throw .malformed("Invalid node transform or opacity", offset: nil)
        }
        let index = nodes.count
        nodes.append([:])
        var result: [String: Any] = [:]
        if node.transform != .identity { result["matrix"] = node.transform.columnMajorElements }
        if let name = node.name { result["name"] = name }
        if let geometry = node.geometry { result["mesh"] = try mesh(geometry, opacity: opacity) }
        if !omitCamerasAndLights {
            if let camera = node.camera {
                result["camera"] = cameras.count
                cameras.append(try GLTFCameraLightCodec.encodeCamera(camera, fallbackAspect: cameraAspectRatio))
            }
            if let light = node.light {
                result["extensions"] = ["KHR_lights_punctual": ["light": lights.count]]
                lights.append(try GLTFCameraLightCodec.encodeLight(light))
            }
        }
        var children: [Int] = []
        for child in node.children {
            if let childIndex = try self.node(child, opacity: opacity, depth: depth + 1) { children.append(childIndex) }
        }
        if !children.isEmpty { result["children"] = children }
        nodes[index] = result
        return index
    }

    mutating func view(_ bytes: [UInt8], target: Int? = nil) -> Int {
        while binary.count % 4 != 0 { binary.append(0) }
        var result: [String: Any] = ["buffer": 0, "byteOffset": binary.count, "byteLength": bytes.count]
        if let target { result["target"] = target }
        binary += bytes
        views.append(result)
        return views.count - 1
    }

    mutating func mesh(_ geometry: Geometry, opacity: Float) throws(SceneFormatError) -> Int {
        let mesh = geometry.mesh
        guard mesh.vertexCount > 0, mesh.vertexCount < Int(UInt32.max), mesh.stream(.position) != nil else {
            throw .malformed("GLB mesh requires positions", offset: nil)
        }
        var attributes: [String: Int] = [:]
        for stream in mesh.streams {
            let name: String
            let dimensions: [Int]
            switch stream.semantic {
            case .position: name = "POSITION"; dimensions = [3]
            case .normal: name = "NORMAL"; dimensions = [3]
            case .tangent: name = "TANGENT"; dimensions = [4]
            case .color: name = "COLOR_0"; dimensions = [3, 4]
            case .textureCoordinate(let channel):
                guard channel >= 0, channel <= 1 else { throw .unsupported("GLB UV channels beyond 1") }
                name = "TEXCOORD_\(channel)"; dimensions = [2]
            case .jointIndices, .jointWeights: continue // Snapshot already contains the deformed pose.
            default: throw .unsupported("GLB vertex semantic \(stream.semantic)")
            }
            guard dimensions.contains(stream.componentCount),
                  stream.data.count / stream.componentCount == mesh.vertexCount,
                  stream.data.count % stream.componentCount == 0, stream.data.allSatisfy(\.isFinite),
                  attributes[name] == nil else { throw .malformed("Invalid \(name) stream", offset: nil) }
            var values = stream.data
            if name == "NORMAL" || name == "TANGENT" {
                for i in stride(from: 0, to: values.count, by: stream.componentCount) {
                    let n = SIMD3(values[i], values[i + 1], values[i + 2]).normalized
                    guard n.lengthSquared > 0 else { throw .malformed("Zero normal or tangent", offset: nil) }
                    values[i] = n.x; values[i + 1] = n.y; values[i + 2] = n.z
                    if name == "TANGENT", abs(values[i + 3]) != 1 { throw .malformed("Invalid tangent sign", offset: nil) }
                }
            }
            if name == "COLOR_0", !values.allSatisfy({ (0...1).contains($0) }) {
                throw .malformed("Vertex color outside 0...1", offset: nil)
            }
            let bufferView = view(words(values.map(\.bitPattern)), target: 34962)
            var accessor: [String: Any] = ["bufferView": bufferView, "componentType": 5126,
                "count": mesh.vertexCount, "type": "VEC\(stream.componentCount)"]
            if name == "POSITION" {
                accessor["min"] = (0..<3).map { axis in stride(from: axis, to: values.count, by: 3).map { values[$0] }.min() ?? 0 }
                accessor["max"] = (0..<3).map { axis in stride(from: axis, to: values.count, by: 3).map { values[$0] }.max() ?? 0 }
            }
            attributes[name] = accessors.count
            accessors.append(accessor)
        }
        let count = mesh.indices?.count ?? mesh.vertexCount
        let submeshes = mesh.submeshes.isEmpty ? [Submesh(range: 0..<count, materialIndex: 0)] : mesh.submeshes
        var primitives: [[String: Any]] = []
        for (index, submesh) in submeshes.enumerated() {
            guard submesh.range.lowerBound >= 0, submesh.range.upperBound <= count, !submesh.range.isEmpty else {
                throw .malformed("Invalid submesh range", offset: nil)
            }
            let mode: Int
            switch submesh.primitive {
            case .points: mode = 0
            case .lines: mode = 1
            case .lineStrip: mode = 3
            case .triangles: mode = 4
            case .triangleStrip: mode = 5
            }
            let n = submesh.range.count
            guard (mode != 1 || n % 2 == 0), (mode != 4 || n % 3 == 0),
                  (mode != 3 || n >= 2), (mode != 5 || n >= 3) else {
                throw .malformed("Incomplete primitive", offset: nil)
            }
            var indices: [UInt32] = []
            for i in submesh.range {
                let value = mesh.indices?[i] ?? i
                guard value >= 0, value < mesh.vertexCount else { throw .malformed("Index out of range", offset: nil) }
                indices.append(UInt32(value))
            }
            let bufferView = view(words(indices), target: 34963)
            let accessor = accessors.count
            accessors.append(["bufferView": bufferView, "componentType": 5125, "count": n, "type": "SCALAR"])
            let material = try material(geometry.material(forSubmesh: index).descriptor, opacity: opacity, attributes: attributes)
            primitives.append(["attributes": attributes, "indices": accessor, "mode": mode, "material": material])
        }
        var result: [String: Any] = ["primitives": primitives]
        if let name = geometry.name { result["name"] = name }
        meshes.append(result)
        return meshes.count - 1
    }

    mutating func material(_ m: MaterialDescriptor, opacity: Float, attributes: [String: Int]) throws(SceneFormatError) -> Int {
        guard m.transparent.contents == .none, m.cullMode == .back,
              m.blendMode == .alpha || m.blendMode == .replace,
              m.readsFromDepthBuffer, m.writesToDepthBuffer else {
            throw .unsupported("GLB separate transparency maps, front culling or custom blend/depth state")
        }
        var base = (m.diffuse.color ?? SIMD4(repeating: 1)) * m.diffuseFactor
        base.x *= m.diffuse.intensity; base.y *= m.diffuse.intensity; base.z *= m.diffuse.intensity
        base.w *= m.transparency * opacity
        let color = [base.x, base.y, base.z, base.w]
        guard color.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw .malformed("Invalid base color", offset: nil) }
        var pbr: [String: Any] = ["baseColorFactor": color]
        pbr["baseColorTexture"] = try texture(m.diffuse, attributes: attributes)
        let metallic = m.lightingModel == .physicallyBased ? (m.metalness.color?.x ?? 1) * m.metalnessFactor : 0
        let roughness = m.lightingModel == .physicallyBased ? (m.roughness.color?.x ?? 1) * m.roughnessFactor : 1
        guard [metallic, roughness].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw .malformed("Invalid metallic/roughness factor", offset: nil)
        }
        pbr["metallicFactor"] = metallic; pbr["roughnessFactor"] = roughness
        if case .texture = m.metalness.contents {
            guard m.metalness == m.roughness else { throw .unsupported("GLB requires a shared packed metallic-roughness texture") }
            pbr["metallicRoughnessTexture"] = try texture(m.metalness, attributes: attributes)
        } else if case .texture = m.roughness.contents {
            throw .unsupported("GLB requires a shared packed metallic-roughness texture")
        }
        var result: [String: Any] = ["pbrMetallicRoughness": pbr, "doubleSided": m.isDoubleSided]
        if let name = m.name { result["name"] = name }
        let emissionBase: SIMD3<Float>
        if case .texture = m.emission.contents { emissionBase = SIMD3(repeating: 1) }
        else { emissionBase = m.emission.color?.xyz ?? .zero }
        let emission = emissionBase * m.emissionFactor * m.emission.intensity
        let emissive = [emission.x, emission.y, emission.z]
        guard emissive.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw .unsupported("HDR emissive export") }
        result["emissiveFactor"] = emissive
        result["emissiveTexture"] = try texture(m.emission, attributes: attributes)
        result["normalTexture"] = try texture(m.normal, attributes: attributes)
        result["occlusionTexture"] = try texture(m.ambientOcclusion, attributes: attributes)
        switch m.alphaMode {
        case .legacy: result["alphaMode"] = base.w < 1 ? "BLEND" : "OPAQUE"
        case .opaque: result["alphaMode"] = opacity < 1 ? "BLEND" : "OPAQUE"
        case .blend: result["alphaMode"] = "BLEND"
        case .mask(let cutoff):
            guard cutoff.isFinite, cutoff >= 0 else { throw .malformed("Invalid alpha cutoff", offset: nil) }
            result["alphaMode"] = "MASK"; result["alphaCutoff"] = cutoff
        }
        if m.lightingModel == .unlit {
            usesUnlit = true
            result["extensions"] = ["KHR_materials_unlit": [String: String]()]
        }
        materials.append(result)
        return materials.count - 1
    }

    mutating func texture(_ property: MaterialProperty, attributes: [String: Int]) throws(SceneFormatError) -> [String: Any]? {
        guard case .texture(let source) = property.contents else { return nil }
        guard property.contentsTransform == .identity, property.intensity == 1,
              attributes["TEXCOORD_\(property.mappingChannel)"] != nil else {
            throw .unsupported("GLB texture transform/intensity or missing UV channel")
        }
        guard let image = TextureImageLoader.load(source) else { throw .unsupported("Cannot resolve GLB texture \(source)") }
        let bufferView = view(try PNGEncoder.encode(image))
        let imageIndex = images.count
        images.append(["bufferView": bufferView, "mimeType": "image/png"])
        func wrap(_ mode: TextureWrapMode) throws(SceneFormatError) -> Int {
            switch mode {
            case .clamp: 33071
            case .repeat: 10497
            case .mirror: 33648
            case .clampToBorder: throw .unsupported("GLB clamp-to-border sampling")
            }
        }
        let sampler = property.sampler
        let nearest = sampler.minificationFilter != .linear
        let minFilter: Int
        switch sampler.mipFilter {
        case .none: minFilter = nearest ? 9728 : 9729
        case .nearest: minFilter = nearest ? 9984 : 9985
        case .linear: minFilter = nearest ? 9986 : 9987
        }
        let samplerIndex = samplers.count
        samplers.append(["wrapS": try wrap(sampler.wrapS), "wrapT": try wrap(sampler.wrapT),
                         "minFilter": minFilter, "magFilter": sampler.magnificationFilter == .linear ? 9729 : 9728])
        let index = textures.count
        textures.append(["source": imageIndex, "sampler": samplerIndex])
        return ["index": index, "texCoord": property.mappingChannel]
    }

    func words(_ values: [UInt32]) -> [UInt8] {
        values.flatMap { value in (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
    }
}
