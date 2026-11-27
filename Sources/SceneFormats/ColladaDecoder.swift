import Foundation
import SceneCore
import SceneGraph

/// COLLADA 1.4/1.5 scene loader with indexed mesh sources, material bindings and ordered transforms.
public struct ColladaDecoder: SceneAssetDecoder {
    public static let fileExtensions = ["dae"]
    public var resourceLoader: SceneResourceLoader?
    public init(resourceLoader: SceneResourceLoader? = nil) { self.resourceLoader = resourceLoader }
    public func decode(_ data: [UInt8]) async throws(SceneFormatError) -> Scene { try decodeScene(data) }
    public func decodeScene(_ data: [UInt8]) throws(SceneFormatError) -> Scene {
        let root = try AssetXML.parse(data)
        guard root.name == "COLLADA" else { throw .invalidHeader("Not a COLLADA document") }
        return try ColladaBuilder(root: root, resourceLoader: resourceLoader).build()
    }
}

private final class ColladaBuilder {
    let root: AssetXML
    let resourceLoader: SceneResourceLoader?
    var ids: [String: AssetXML] = [:]

    init(root: AssetXML, resourceLoader: SceneResourceLoader?) throws(SceneFormatError) {
        self.root = root
        self.resourceLoader = resourceLoader
        func collect(_ node: AssetXML) throws(SceneFormatError) {
            if let id = node.attributes["id"] {
                guard ids[id] == nil else { throw .malformed("Duplicate COLLADA id", offset: nil) }
                ids[id] = node
            }
            for child in node.children { try collect(child) }
        }
        try collect(root)
    }

    func reference(_ uri: String?) throws(SceneFormatError) -> AssetXML {
        guard let uri, uri.hasPrefix("#"), let node = ids[String(uri.dropFirst())] else {
            throw .malformed("Missing or external COLLADA reference: \(uri ?? "")", offset: nil)
        }
        return node
    }

    func build() throws(SceneFormatError) -> Scene {
        let scene = Scene()
        let visual = try reference(root["scene"]?["instance_visual_scene"]?.attributes["url"])
        guard visual.name == "visual_scene" else { throw .malformed("Expected visual scene", offset: nil) }
        for child in visual.all("node") { scene.rootNode.addChild(try node(child, visited: [])) }
        let unit = root["asset"]?["unit"]?.attributes["meter"].flatMap(Float.init) ?? 1
        guard unit.isFinite, unit > 0 else { throw .malformed("Invalid COLLADA unit", offset: nil) }
        let up = root["asset"]?["up_axis"]?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Y_UP"
        let rotation: Quaternion
        switch up {
        case "Y_UP": rotation = .identity
        case "Z_UP": rotation = Quaternion(angle: -.pi / 2, axis: [1, 0, 0])
        case "X_UP": rotation = Quaternion(angle: .pi / 2, axis: [0, 0, 1])
        default: throw .malformed("Unknown COLLADA up axis", offset: nil)
        }
        scene.rootNode.transform = Matrix4x4(rotation: rotation) * Matrix4x4(scale: SIMD3(repeating: unit))
        return scene
    }

    func node(_ source: AssetXML, visited: Set<ObjectIdentifier>) throws(SceneFormatError) -> Node {
        var visited = visited
        guard visited.insert(ObjectIdentifier(source)).inserted, visited.count < 128 else {
            throw .malformed("Cyclic COLLADA node instancing", offset: nil)
        }
        let node = Node(name: source.attributes["name"] ?? source.attributes["id"] ?? source.attributes["sid"])
        var transform = Matrix4x4.identity
        for child in source.children {
            switch child.name {
            case "matrix":
                let values = try child.floats()
                guard values.count == 16 else { throw .malformed("Invalid COLLADA matrix", offset: nil) }
                transform = transform * Matrix4x4(columnMajor: values).transpose
            case "translate", "scale":
                let values = try child.floats()
                guard values.count == 3 else { throw .malformed("Invalid COLLADA transform", offset: nil) }
                let vector = SIMD3(values[0], values[1], values[2])
                transform = transform * (child.name == "translate" ? Matrix4x4(translation: vector) : Matrix4x4(scale: vector))
            case "rotate":
                let values = try child.floats()
                guard values.count == 4 else { throw .malformed("Invalid COLLADA rotation", offset: nil) }
                transform = transform * Matrix4x4(rotation: Quaternion(angle: values[3] * .pi / 180, axis: SIMD3(values[0], values[1], values[2])))
            case "lookat":
                let v = try child.floats()
                guard v.count == 9 else { throw .malformed("Invalid lookat", offset: nil) }
                let matrix = Matrix4x4.lookAt(eye: SIMD3(v[0], v[1], v[2]), target: SIMD3(v[3], v[4], v[5]), up: SIMD3(v[6], v[7], v[8]))
                guard let inverse = matrix.inverse else { throw .malformed("Singular lookat", offset: nil) }
                transform = transform * inverse
            case "node": node.addChild(try self.node(child, visited: visited))
            case "instance_node": node.addChild(try self.node(reference(child.attributes["url"]), visited: visited))
            case "instance_geometry":
                let geometry = try reference(child.attributes["url"])
                let bindings = child["bind_material"]?["technique_common"]?.all("instance_material") ?? []
                var materials: [String: Material] = [:]
                for binding in bindings {
                    guard let symbol = binding.attributes["symbol"] else { throw .malformed("Missing material symbol", offset: nil) }
                    materials[symbol] = try material(reference(binding.attributes["target"]))
                }
                for part in try meshes(geometry, materials: materials) { node.addChild(Node(geometry: part)) }
            case "instance_light": node.light = try light(reference(child.attributes["url"]))
            case "instance_camera": node.camera = try camera(reference(child.attributes["url"]))
            case "instance_controller": throw .unsupported("COLLADA controllers are not yet supported")
            case "skew": throw .unsupported("COLLADA skew transforms are not supported")
            default: break
            }
        }
        node.transform = transform
        return node
    }

    struct Input {
        var semantic: VertexSemantic
        var offset: Int
        var components: Int
        var stride: Int
        var sourceOffset: Int
        var count: Int
        var values: [Float]
    }

    func input(_ node: AssetXML, offset: Int) throws(SceneFormatError) -> Input? {
        guard let semantic = node.attributes["semantic"] else { throw .malformed("Missing input semantic", offset: nil) }
        let key: VertexSemantic
        let components: Int
        switch semantic {
        case "POSITION": key = .position; components = 3
        case "NORMAL": key = .normal; components = 3
        case "TEXCOORD": key = .textureCoordinate(Int(node.attributes["set"] ?? "0") ?? 0); components = 2
        case "COLOR": key = .color; components = 3
        default: return nil
        }
        let source = try reference(node.attributes["source"])
        guard let accessor = source["technique_common"]?["accessor"],
              let countText = accessor.attributes["count"], let count = Int(countText), count >= 0 else {
            throw .malformed("Missing source accessor", offset: nil)
        }
        let array = try reference(accessor.attributes["source"])
        let values = try array.floats()
        let stride = Int(accessor.attributes["stride"] ?? "1") ?? 0
        let sourceOffset = Int(accessor.attributes["offset"] ?? "0") ?? -1
        guard stride >= components, stride <= 1024, sourceOffset >= 0, sourceOffset <= values.count,
              count <= (values.count - sourceOffset) / stride else {
            throw .malformed("Source accessor exceeds array", offset: nil)
        }
        return Input(semantic: key, offset: offset, components: components, stride: stride,
                     sourceOffset: sourceOffset, count: count, values: values)
    }

    func meshes(_ geometry: AssetXML, materials: [String: Material]) throws(SceneFormatError) -> [Geometry] {
        guard let mesh = geometry["mesh"] else { throw .unsupported("Non-mesh COLLADA geometry") }
        var result: [Geometry] = []
        for primitive in mesh.children where ["triangles", "polylist", "polygons", "tristrips", "trifans", "lines", "linestrips"].contains(primitive.name) {
            var inputs: [Input] = []
            var tupleSize = 0
            for source in primitive.all("input") {
                guard let offset = Int(source.attributes["offset"] ?? "0"), offset >= 0, offset < 1024 else {
                    throw .malformed("Invalid input offset", offset: nil)
                }
                tupleSize = max(tupleSize, offset + 1)
                if source.attributes["semantic"] == "VERTEX" {
                    let vertices = try reference(source.attributes["source"])
                    for child in vertices.all("input") {
                        if let input = try input(child, offset: offset) { inputs.append(input) }
                    }
                } else if let input = try input(source, offset: offset) { inputs.append(input) }
            }
            guard tupleSize > 0, inputs.contains(where: { $0.semantic == .position }),
                  Set(inputs.map(\.semantic)).count == inputs.count else { throw .malformed("Invalid mesh inputs", offset: nil) }
            var streams = inputs.map { _ in [Float]() }
            var indices: [Int] = []
            var topology = PrimitiveType.triangles
            let runs: [[Int]]
            if primitive.name == "polylist" {
                let counts = try primitive["vcount"]?.integers() ?? []
                let values = try primitive["p"]?.integers() ?? []
                var position = 0
                var split: [[Int]] = []
                for count in counts {
                    guard count <= (values.count - position) / tupleSize else { throw .malformed("Polygon exceeds index data", offset: nil) }
                    split.append(Array(values[position..<position + count * tupleSize]))
                    position += count * tupleSize
                }
                guard position == values.count else { throw .malformed("Extra polygon index data", offset: nil) }
                runs = split
            } else {
                guard primitive.all("ph").isEmpty else { throw .unsupported("COLLADA polygons with holes") }
                var values: [[Int]] = []
                for p in primitive.all("p") { values.append(try p.integers()) }
                runs = values
            }
            for run in runs {
                guard run.count % tupleSize == 0 else { throw .malformed("Incomplete index tuple", offset: nil) }
                let count = run.count / tupleSize
                let base = streams[0].count / inputs[0].components
                for vertex in 0..<count {
                    for (streamIndex, input) in inputs.enumerated() {
                        let index = run[vertex * tupleSize + input.offset]
                        guard index < input.count else { throw .malformed("Vertex index exceeds source", offset: nil) }
                        let start = input.sourceOffset + index * input.stride
                        var components = Array(input.values[start..<start + input.components])
                        if case .textureCoordinate = input.semantic { components[1] = 1 - components[1] }
                        streams[streamIndex] += components
                    }
                }
                switch primitive.name {
                case "triangles":
                    guard count % 3 == 0 else { throw .malformed("Incomplete triangles", offset: nil) }
                    indices += Array(base..<base + count)
                case "lines":
                    guard count % 2 == 0 else { throw .malformed("Incomplete lines", offset: nil) }
                    topology = .lines; indices += Array(base..<base + count)
                case "linestrips":
                    topology = .lines
                    if count >= 2 { indices += (0..<count - 1).flatMap { [base + $0, base + $0 + 1] } }
                case "tristrips":
                    if count >= 3 {
                        for i in 0..<count - 2 {
                            indices.append(base + i)
                            indices.append(base + i + (i % 2 == 0 ? 1 : 2))
                            indices.append(base + i + (i % 2 == 0 ? 2 : 1))
                        }
                    }
                default:
                    guard count >= 3, let positionIndex = inputs.firstIndex(where: { $0.semantic == .position }) else { continue }
                    let points = (0..<count).map { i -> SIMD3<Float> in
                        let start = (base + i) * 3
                        return SIMD3(streams[positionIndex][start], streams[positionIndex][start + 1], streams[positionIndex][start + 2])
                    }
                    let triangles = Triangulation.triangulate([points])
                    indices += triangles.flatMap { [base + $0.x, base + $0.y, base + $0.z] }
                }
            }
            let count = streams[0].count / inputs[0].components
            if count == 0 { continue }
            let vertexStreams = zip(inputs, streams).map { VertexStream(semantic: $0.semantic, componentCount: $0.components, data: $1) }
            var buffer = MeshBuffer(vertexCount: count, streams: vertexStreams, indices: IndexBuffer(indices),
                                    submeshes: [Submesh(primitive: topology, range: 0..<indices.count, materialIndex: 0)])
            if topology == .triangles, buffer.stream(.normal) == nil {
                var normals = [SIMD3<Float>](repeating: .zero, count: count)
                let positions = buffer.positions
                for triangle in buffer.triangles(in: buffer.submeshes[0]) {
                    let normal = (positions[triangle.y] - positions[triangle.x]).cross(positions[triangle.z] - positions[triangle.x]).normalized
                    for index in [triangle.x, triangle.y, triangle.z] { normals[index] += normal }
                }
                buffer.streams.append(VertexStream(semantic: .normal, vectors: normals.map(\.normalized)))
            }
            let material = primitive.attributes["material"].flatMap { materials[$0] } ?? Material()
            result.append(Geometry(mesh: buffer, materials: [material]))
        }
        return result
    }

    func material(_ source: AssetXML) throws(SceneFormatError) -> Material {
        let effect = try reference(source["instance_effect"]?.attributes["url"])
        guard let profile = effect["profile_COMMON"], let technique = profile["technique"],
              let shader = technique.children.first(where: { ["phong", "blinn", "lambert", "constant"].contains($0.name) }) else {
            throw .unsupported("COLLADA material requires profile_COMMON")
        }
        var material = MaterialDescriptor()
        material.name = source.attributes["name"] ?? source.attributes["id"]
        switch shader.name {
        case "lambert": material.lightingModel = .lambert
        case "constant": material.lightingModel = .unlit
        case "phong": material.lightingModel = .phong
        default: material.lightingModel = .blinn
        }
        func property(_ name: String) throws(SceneFormatError) -> MaterialProperty? {
            guard let node = shader[name] else { return nil }
            if let color = node["color"] {
                let values = try color.floats()
                guard values.count == 4 else { throw .malformed("Invalid material color", offset: nil) }
                return .color(SIMD4(values[0], values[1], values[2], values[3]))
            }
            if let texture = node["texture"], let samplerID = texture.attributes["texture"] {
                let sampler = profile.all("newparam").first { $0.attributes["sid"] == samplerID }
                let surfaceID = sampler?["sampler2D"]?["source"]?.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let surface = profile.all("newparam").first { $0.attributes["sid"] == surfaceID }
                let imageID = surface?["surface"]?["init_from"]?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? samplerID
                guard let image = ids[imageID], let uri = image["init_from"]?.text.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    throw .malformed("Missing COLLADA texture image", offset: nil)
                }
                let bytes = try GLTFStorage.resource(uri, loader: resourceLoader)
                return .texture(.image(try TextureImageLoader.decodeImage(bytes)))
            }
            return nil
        }
        material.diffuse = try property("diffuse") ?? material.diffuse
        material.ambient = try property("ambient") ?? material.ambient
        material.specular = try property("specular") ?? material.specular
        material.emission = try property("emission") ?? material.emission
        if let value = try shader["shininess"]?["float"]?.floats().first { material.shininess = value / 128 }
        if let value = try shader["transparency"]?["float"]?.floats().first { material.transparency = value }
        return Material(material)
    }

    func light(_ source: AssetXML) throws(SceneFormatError) -> Light {
        guard let value = source["technique_common"]?.children.first else { throw .malformed("Missing light", offset: nil) }
        var descriptor = LightDescriptor()
        switch value.name {
        case "ambient": descriptor.kind = .ambient
        case "directional": descriptor.kind = .directional
        case "point": descriptor.kind = .omni
        case "spot": descriptor.kind = .spot
        default: throw .unsupported("COLLADA light type")
        }
        let color = try value["color"]?.floats() ?? [1, 1, 1]
        guard color.count == 3 else { throw .malformed("Invalid light color", offset: nil) }
        descriptor.color = SIMD3(color[0], color[1], color[2])
        if let angle = try value["falloff_angle"]?.floats().first { descriptor.spotOuterAngle = angle }
        return Light(descriptor)
    }

    func camera(_ source: AssetXML) throws(SceneFormatError) -> Camera {
        guard let value = source["optics"]?["technique_common"]?.children.first else { throw .malformed("Missing camera", offset: nil) }
        var descriptor = CameraDescriptor()
        if value.name == "orthographic" {
            descriptor.usesOrthographicProjection = true
            descriptor.orthographicScale = try value["ymag"]?.floats().first ?? 1
        } else if value.name == "perspective" {
            let yfov = try value["yfov"]?.floats().first
            let xfov = try value["xfov"]?.floats().first
            descriptor.fieldOfView = yfov ?? xfov ?? 60
            if yfov == nil, xfov != nil { descriptor.projectionDirection = .horizontal }
        } else { throw .unsupported("COLLADA camera type") }
        descriptor.aspectRatio = try value["aspect_ratio"]?.floats().first
        descriptor.zNear = try value["znear"]?.floats().first ?? 0.1
        descriptor.zFar = try value["zfar"]?.floats().first ?? 1000
        return Camera(descriptor)
    }
}
