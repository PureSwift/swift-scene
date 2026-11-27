import Foundation
import SceneCore
import SceneGraph

/// Reads SceneKit keyed archives as data, without loading Objective-C classes or executing archive code.
/// Supports retained nodes, mesh buffers, procedural shapes, materials, lights and cameras.
public struct SCNArchiveDecoder: SceneAssetDecoder {
    public static let fileExtensions = ["scn"]
    public var resourceLoader: SceneResourceLoader?

    public init(resourceLoader: SceneResourceLoader? = nil) { self.resourceLoader = resourceLoader }

    public func decode(_ bytes: [UInt8]) async throws(SceneFormatError) -> Scene { try decodeScene(bytes) }

    public func decodeScene(_ bytes: [UInt8]) throws(SceneFormatError) -> Scene {
        var plist = BinaryPropertyList(bytes)
        return try SCNArchive(plist.parse(), resourceLoader: resourceLoader).scene()
    }
}

private final class SCNArchive {
    let objects: [AssetPlistValue]
    let root: AssetPlistValue
    let resourceLoader: SceneResourceLoader?
    var nodes: Set<Int> = []

    init(_ value: AssetPlistValue, resourceLoader: SceneResourceLoader?) throws(SceneFormatError) {
        guard let archive = value.dictionary, ["NSKeyedArchiver", "SCNKeyedArchiver"].contains(archive["$archiver"]?.string ?? ""),
              let objects = archive["$objects"]?.array, let root = archive["$top"]?.dictionary?["root"] else {
            throw .invalidHeader("Expected a SceneKit keyed archive")
        }
        self.objects = objects
        self.root = root
        self.resourceLoader = resourceLoader
    }

    func resolve(_ value: AssetPlistValue?) throws(SceneFormatError) -> AssetPlistValue {
        guard let value else { return .null }
        if case .uid(let index) = value {
            guard objects.indices.contains(index) else { throw .malformed("Invalid archive UID", offset: nil) }
            return index == 0 ? .null : objects[index]
        }
        return value
    }

    func dictionary(_ value: AssetPlistValue?) throws(SceneFormatError) -> [String: AssetPlistValue] {
        guard let dictionary = try resolve(value).dictionary else { throw .malformed("Expected archived object", offset: nil) }
        guard dictionary.values.allSatisfy({ $0.number.map { abs($0) <= Double(Float.greatestFiniteMagnitude) } ?? true }) else {
            throw .malformed("Archived numeric value is out of range", offset: nil)
        }
        return dictionary
    }

    func className(_ value: [String: AssetPlistValue]) throws(SceneFormatError) -> String {
        try dictionary(value["$class"])["$classname"]?.string ?? ""
    }

    func string(_ value: AssetPlistValue?) throws(SceneFormatError) -> String? { try resolve(value).string }

    func array(_ value: AssetPlistValue?) throws(SceneFormatError) -> [AssetPlistValue] {
        let value = try resolve(value)
        if case .null = value { return [] }
        if let array = value.array { return array }
        guard let array = value.dictionary?["NS.objects"]?.array else { throw .malformed("Expected archive array", offset: nil) }
        return array
    }

    func data(_ value: AssetPlistValue?) throws(SceneFormatError) -> [UInt8] {
        let value = try resolve(value)
        if let bytes = value.data { return bytes }
        if let bytes = value.dictionary?["NS.bytes"]?.data { return bytes }
        throw .malformed("Expected archived data", offset: nil)
    }

    func floats(_ value: AssetPlistValue?, count: Int) throws(SceneFormatError) -> [Float]? {
        guard let value else { return nil }
        let bytes = try data(value)
        guard bytes.count == count * 4 else { throw .malformed("Invalid archived vector size", offset: nil) }
        let values = (0..<count).map { Float(bitPattern: GLTFStorage.word(bytes, $0 * 4)) }
        guard values.allSatisfy(\.isFinite) else { throw .malformed("Non-finite archived vector", offset: nil) }
        return values
    }

    func scene() throws(SceneFormatError) -> Scene {
        let source = try dictionary(root)
        let scene = Scene()
        switch try className(source) {
        case "SCNScene": scene.rootNode.addChild(try node(source["rootNode"], depth: 0))
        case "SCNNode": scene.rootNode.addChild(try node(root, depth: 0))
        default: throw .unsupported("Archive root is not a scene or node")
        }
        return scene
    }

    func node(_ value: AssetPlistValue?, depth: Int) throws(SceneFormatError) -> Node {
        guard depth < 256, case .uid(let index) = value, nodes.insert(index).inserted else {
            throw .malformed("Cyclic or shared archived node", offset: nil)
        }
        let source = try dictionary(value)
        guard try className(source) == "SCNNode" else { throw .unsupported("Archived node subclass") }
        for key in ["skinner", "morpher"] {
            if case .null = try resolve(source[key]) {} else { throw .unsupported("SCN \(key)") }
        }
        let node = Node(name: try string(source["name"]))
        if let v = try floats(source["position"], count: 3) { node.position = SIMD3(v[0], v[1], v[2]) }
        if let v = try floats(source["scale"], count: 3) { node.scale = SIMD3(v[0], v[1], v[2]) }
        if let v = try floats(source["orientation"], count: 4) { node.orientation = Quaternion(ix: v[0], iy: v[1], iz: v[2], r: v[3]) }
        if let v = try floats(source["transform"], count: 16) { node.transform = Matrix4x4(columnMajor: v) }
        if let v = try floats(source["pivot"], count: 16) { node.pivot = Matrix4x4(columnMajor: v) }
        node.opacity = Float(source["opacity"]?.number ?? 1)
        node.isHidden = source["hidden"]?.number == 1
        if let value = source["categoryBitMask"]?.number, let mask = Int(exactly: value) { node.categoryBitMask = mask }
        if case .null = try resolve(source["geometry"]) {} else { node.geometry = try geometry(source["geometry"]) }
        if case .null = try resolve(source["camera"]) {} else { node.camera = try camera(source["camera"]) }
        if case .null = try resolve(source["light"]) {} else { node.light = try light(source["light"]) }
        for child in try array(source["childNodes"]) { node.addChild(try self.node(child, depth: depth + 1)) }
        return node
    }

    func geometry(_ value: AssetPlistValue?) throws(SceneFormatError) -> Geometry {
        let source = try dictionary(value)
        let name = try className(source)
        var materials: [Material] = []
        for value in try array(source["materials"]) { materials.append(try material(value)) }
        func number(_ key: String, _ fallback: Float = 1) -> Float { Float(source[key]?.number ?? Double(fallback)) }
        let primitive: Primitive?
        switch name {
        case "SCNBox": primitive = .box(width: number("boxwidth"), height: number("boxheight"), length: number("boxlength"))
        case "SCNSphere": primitive = .sphere(radius: number("sphereradius"))
        case "SCNPlane": primitive = .plane(width: number("width"), height: number("height"))
        case "SCNCylinder": primitive = .cylinder(radius: number("cylinderradius"), height: number("cylinderheight"))
        case "SCNCone": primitive = .cone(topRadius: number("conetopRadius", 0), bottomRadius: number("conebottomRadius"), height: number("coneheight"))
        case "SCNTorus": primitive = .torus(ringRadius: number("torusringRadius"), pipeRadius: number("toruspipeRadius", 0.25))
        case "SCNCapsule": primitive = .capsule(capRadius: number("capsulecapRadius", 0.5), height: number("capsuleheight", 2))
        case "SCNFloor": primitive = .floor(width: number("floorwidth", 0), length: number("floorlength", 0))
        case "SCNGeometry": primitive = nil
        default: throw .unsupported("Archived geometry \(name)")
        }
        if let primitive { return Geometry(primitive, materials: materials) }
        var streams: [VertexStream] = []
        var vertexCount: Int?
        for (key, semantic) in [("Vertex", VertexSemantic.position), ("Normal", .normal), ("Color", .color), ("Texcoord", .textureCoordinate(0)), ("Tangent", .tangent)] {
            for (channel, value) in try array(source["kGeometrySourceSemantic\(key)"]).enumerated() {
                let stream = try vertexSource(value, semantic: key == "Texcoord" ? .textureCoordinate(channel) : semantic)
                let count = stream.data.count / stream.componentCount
                if let vertexCount, count != vertexCount { throw .malformed("Mismatched archived vertex counts", offset: nil) }
                vertexCount = count
                streams.append(stream)
            }
        }
        guard let vertexCount, streams.contains(where: { $0.semantic == .position }) else { throw .malformed("Mesh has no positions", offset: nil) }
        var indices: [Int] = []
        var submeshes: [Submesh] = []
        for (material, value) in try array(source["elements"]).enumerated() {
            let element = try dictionary(value)
            let width = Int(exactly: element["bytesPerIndex"]?.number ?? 0) ?? 0
            let countValue = element["primitiveCount"]?.number ?? -1
            guard let count = Int(exactly: countValue), count >= 0, count <= 16_000_000,
                  [1, 2, 4].contains(width), (element["indicesChannelCount"]?.number ?? 1) == 1 else {
                throw .malformed("Invalid archived element", offset: nil)
            }
            let type = element["primitiveType"]?.number ?? 0
            let topology: PrimitiveType
            let indexCount: Int
            switch type {
            case 0: topology = .triangles; indexCount = count * 3
            case 1: topology = .triangleStrip; indexCount = count == 0 ? 0 : count + 2
            case 2: topology = .lines; indexCount = count * 2
            case 3: topology = .points; indexCount = count
            default: throw .unsupported("Archived polygon element")
            }
            let bytes = try data(element["elementData"])
            guard indexCount <= bytes.count / width else { throw .malformed("Truncated element indices", offset: nil) }
            let start = indices.count
            for i in 0..<indexCount {
                var index = 0
                for j in 0..<width { index |= Int(bytes[i * width + j]) << (j * 8) }
                guard index < vertexCount else { throw .malformed("Archived index out of range", offset: nil) }
                indices.append(index)
            }
            submeshes.append(Submesh(primitive: topology, range: start..<indices.count, materialIndex: material))
        }
        return Geometry(mesh: MeshBuffer(vertexCount: vertexCount, streams: streams, indices: IndexBuffer(indices), submeshes: submeshes), materials: materials)
    }

    func vertexSource(_ value: AssetPlistValue, semantic: VertexSemantic) throws(SceneFormatError) -> VertexStream {
        let source = try dictionary(value)
        func integer(_ key: String, default fallback: Int = 0) throws(SceneFormatError) -> Int {
            guard let value = Int(exactly: source[key]?.number ?? Double(fallback)), value >= 0 else { throw .malformed("Invalid vertex layout", offset: nil) }
            return value
        }
        let count = try integer("vectorCount"), components = try integer("componentsPerVector")
        let width = try integer("bytesPerComponent"), offset = try integer("dataOffset")
        guard (1...4).contains(components), [1, 2, 4, 8].contains(width), count <= 16_000_000 / components else { throw .unsupported("Archived vertex layout") }
        let stride = try integer("dataStride", default: width * components)
        let bytes = try data(source["data"])
        guard stride >= width * components, offset <= bytes.count,
              count == 0 || (bytes.count - offset >= width * components && count - 1 <= (bytes.count - offset - width * components) / stride) else {
            throw .malformed("Vertex source exceeds data", offset: nil)
        }
        var values: [Float] = []
        for i in 0..<count {
            for j in 0..<components {
                var raw: UInt64 = 0
                for k in 0..<width { raw |= UInt64(bytes[offset + i * stride + j * width + k]) << (k * 8) }
                let value: Float
                if source["floatComponents"]?.number == 1 {
                    switch width {
                    case 4: value = Float(bitPattern: UInt32(raw))
                    case 8: value = Float(Double(bitPattern: raw))
                    default: throw .unsupported("Archived floating-point vertex width")
                    }
                } else { value = Float(raw) / Float(width == 8 ? UInt64.max : (UInt64(1) << (width * 8)) - 1) }
                guard value.isFinite else { throw .malformed("Non-finite vertex", offset: nil) }
                values.append(value)
            }
        }
        if case .textureCoordinate = semantic { for i in 0..<count where components >= 2 { values[i * components + 1] = 1 - values[i * components + 1] } }
        return VertexStream(semantic: semantic, componentCount: components, data: values)
    }

    func material(_ value: AssetPlistValue) throws(SceneFormatError) -> Material {
        let source = try dictionary(value)
        var result = MaterialDescriptor()
        result.name = try string(source["name"])
        switch try string(source["lightingModelName"]) {
        case "SCNLightingModelConstant": result.lightingModel = .unlit
        case "SCNLightingModelLambert": result.lightingModel = .lambert
        case "SCNLightingModelBlinn": result.lightingModel = .blinn
        case "SCNLightingModelPhysicallyBased": result.lightingModel = .physicallyBased
        default: result.lightingModel = .phong
        }
        result.diffuse = try property(source["diffuse"]) ?? result.diffuse
        result.ambient = try property(source["ambient"]) ?? result.ambient
        result.specular = try property(source["specular"]) ?? result.specular
        result.emission = try property(source["emission"]) ?? result.emission
        result.normal = try property(source["normal"]) ?? result.normal
        result.metalness = try property(source["metalness"]) ?? result.metalness
        result.roughness = try property(source["roughness"]) ?? result.roughness
        result.transparency = Float(source["transparency"]?.number ?? 1)
        result.shininess = Float(source["shininess"]?.number ?? 0.5)
        result.isDoubleSided = source["doubleSided"]?.number == 1
        return Material(result)
    }

    func property(_ value: AssetPlistValue?) throws(SceneFormatError) -> MaterialProperty? {
        if case .null = try resolve(value) { return nil }
        let source = try dictionary(value)
        if case .null = try resolve(source["color"]) {} else {
            let color = try dictionary(source["color"])
            if let bytes = color["NSComponents"]?.data ?? color["NSRGB"]?.data ?? color["NSWhite"]?.data,
               let text = String(bytes: bytes.filter { $0 != 0 }, encoding: .utf8) {
                let tokens = text.split(whereSeparator: \.isWhitespace)
                let values = tokens.compactMap(Float.init)
                guard values.count == tokens.count, (1...4).contains(values.count), values.allSatisfy(\.isFinite) else {
                    throw .malformed("Invalid archived color", offset: nil)
                }
                var rgba = values.count >= 3
                    ? SIMD4(values[0], values[1], values[2], values.count > 3 ? values[3] : 1)
                    : SIMD4(values[0], values[0], values[0], values.count > 1 ? values[1] : 1)
                if color["NSComponents"] != nil {
                    let space = try dictionary(color["NSCustomColorSpace"])
                    // NSColor archives use NSID for older spaces and NSSpaceID for newer ones.
                    // NSRGB is a legacy fallback in a different space; prefer tagged NSComponents.
                    switch space["NSID"]?.number ?? space["NSSpaceID"]?.number {
                    case 7, 14: // sRGB and extended sRGB
                        for channel in 0..<3 {
                            let magnitude = abs(rgba[channel])
                            let linear = magnitude <= 0.04045 ? magnitude / 12.92
                                : pow((magnitude + 0.055) / 1.055, 2.4)
                            rgba[channel] = rgba[channel] < 0 ? -linear : linear
                        }
                    case 17: break // Extended linear sRGB is already in the renderer's working space.
                    default: throw .unsupported("Archived custom color space")
                    }
                }
                return .color(rgba)
            }
            throw .unsupported("Archived color space")
        }
        if case .null = try resolve(source["image"]) {} else {
            let image = try dictionary(source["image"])
            let keys = try array(image["NS.keys"])
            let values = try array(image["NS.objects"])
            guard keys.count == values.count else { throw .malformed("Invalid archived image dictionary", offset: nil) }
            for (key, value) in zip(keys, values) {
                if try string(key) == "path", let path = try string(value) {
                    return .texture(.image(try TextureImageLoader.decodeImage(GLTFStorage.resource(path, loader: resourceLoader))))
                }
            }
            throw .unsupported("Embedded SCN image representation")
        }
        if let path = try string(source["path"]) {
            return .texture(.image(try TextureImageLoader.decodeImage(GLTFStorage.resource(path, loader: resourceLoader))))
        }
        if let number = source["float"]?.number ?? source["number"]?.number { return .scalar(Float(number)) }
        return nil
    }

    func camera(_ value: AssetPlistValue?) throws(SceneFormatError) -> Camera {
        let source = try dictionary(value)
        var camera = CameraDescriptor()
        camera.fieldOfView = Float(source["fov"]?.number ?? source["yFov"]?.number ?? 60)
        camera.zNear = Float(source["zNear"]?.number ?? 0.1)
        camera.zFar = Float(source["zFar"]?.number ?? 1000)
        camera.usesOrthographicProjection = source["usesOrthographicProjection"]?.number == 1
        camera.orthographicScale = Float(source["orthographicScale"]?.number ?? 1)
        return Camera(camera)
    }

    func light(_ value: AssetPlistValue?) throws(SceneFormatError) -> Light {
        let source = try dictionary(value)
        var light = LightDescriptor()
        switch try string(source["type"]) {
        case "ambient": light.kind = .ambient
        case "directional": light.kind = .directional
        case "spot": light.kind = .spot
        default: light.kind = .omni
        }
        if let v = try floats(source["scncolor"], count: 4) { light.color = SIMD3(v[0], v[1], v[2]) }
        light.intensity = Float(source["intensity"]?.number ?? 1000)
        light.spotInnerAngle = Float(source["spotInnerAngle"]?.number ?? 0)
        light.spotOuterAngle = Float(source["spotOuterAngle"]?.number ?? 45)
        return Light(light)
    }
}
