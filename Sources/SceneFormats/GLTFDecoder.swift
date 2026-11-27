import Foundation
import SceneCore
import SceneGraph

/// glTF 2.0 and GLB loader. External URIs are resolved only by the supplied callback.
public struct GLTFDecoder: SceneAssetDecoder {
    public static let fileExtensions = ["gltf", "glb"]
    public var resourceLoader: SceneResourceLoader?
    /// Optional image decoder for formats beyond the built-in PNG decoder.
    public var imageDecoder: (([UInt8], String?) throws -> ImageBuffer)?

    public init(resourceLoader: SceneResourceLoader? = nil,
                imageDecoder: (([UInt8], String?) throws -> ImageBuffer)? = nil) {
        self.resourceLoader = resourceLoader
        self.imageDecoder = imageDecoder
    }

    public func decode(_ data: [UInt8]) async throws(SceneFormatError) -> Scene { try decodeScene(data) }

    public func decodeScene(_ data: [UInt8]) throws(SceneFormatError) -> Scene {
        let storage = try GLTFStorage(data, resourceLoader: resourceLoader)
        return try GLTFSceneBuilder(storage: storage, decoder: self).build()
    }
}

private struct GLTFSceneBuilder {
    let storage: GLTFStorage
    let decoder: GLTFDecoder
    var document: GLTFDocument { storage.document }

    func build() throws(SceneFormatError) -> Scene {
        let definitions = document.nodes ?? []
        guard definitions.count <= 100_000 else { throw .unsupported("Too many glTF nodes") }
        let nodes = definitions.map { Node(name: $0.name) }
        var parents = [Int?](repeating: nil, count: nodes.count)
        for (index, definition) in definitions.enumerated() {
            for child in definition.children ?? [] {
                guard nodes.indices.contains(child), child != index, parents[child] == nil else {
                    throw .malformed("Invalid glTF node hierarchy", offset: nil)
                }
                parents[child] = index
            }
        }
        // Validate cycles and depth before attaching references to the scene graph.
        for index in nodes.indices {
            var visited: Set<Int> = []
            var current: Int? = index
            while let node = current {
                guard visited.insert(node).inserted, visited.count < 256 else {
                    throw .malformed("Cyclic or excessively deep glTF hierarchy", offset: nil)
                }
                current = parents[node]
            }
        }
        var materials: [Material] = []
        for source in document.materials ?? [] { materials.append(try material(source)) }
        var primitiveNodes = [[Node]](repeating: [], count: nodes.count)
        for (index, definition) in definitions.enumerated() {
            nodes[index].transform = try transform(definition)
            if let meshIndex = definition.mesh {
                let meshes = document.meshes ?? []
                guard meshes.indices.contains(meshIndex) else { throw .malformed("Invalid mesh index", offset: nil) }
                let mesh = meshes[meshIndex]
                for primitive in mesh.primitives {
                    let geometry = try geometry(primitive, materials: materials)
                    let child = Node(name: mesh.name, geometry: geometry)
                    nodes[index].addChild(child)
                    primitiveNodes[index].append(child)
                }
            }
            if let cameraIndex = definition.camera {
                let cameras = document.cameras ?? []
                guard cameras.indices.contains(cameraIndex) else { throw .malformed("Invalid camera index", offset: nil) }
                nodes[index].camera = try camera(cameras[cameraIndex])
            }
        }
        for (index, definition) in definitions.enumerated() {
            for child in definition.children ?? [] { nodes[index].addChild(nodes[child]) }
        }
        let scene = Scene()
        let scenes = document.scenes ?? []
        let roots: [Int]
        if !scenes.isEmpty {
            let index = document.scene ?? 0
            guard scenes.indices.contains(index) else { throw .malformed("Invalid scene index", offset: nil) }
            roots = scenes[index].nodes ?? []
            scene.rootNode.name = scenes[index].name ?? "root"
        } else {
            guard document.scene == nil else { throw .malformed("Scene index without scenes", offset: nil) }
            roots = nodes.indices.filter { parents[$0] == nil }
        }
        var attached: Set<Int> = []
        for root in roots {
            guard nodes.indices.contains(root), parents[root] == nil, attached.insert(root).inserted else {
                throw .malformed("Invalid scene root", offset: nil)
            }
            scene.rootNode.addChild(nodes[root])
        }
        let runtime = try GLTFSceneRuntime(storage: storage, nodes: nodes, primitiveNodes: primitiveNodes)
        scene.systems.append(runtime)
        runtime.update(scene, by: .zero)
        return scene
    }

    func transform(_ node: GLTFDocument.Node) throws(SceneFormatError) -> Matrix4x4 {
        if let matrix = node.matrix {
            guard matrix.count == 16, matrix.allSatisfy(\.isFinite),
                  node.translation == nil, node.rotation == nil, node.scale == nil else {
                throw .malformed("Invalid glTF matrix transform", offset: nil)
            }
            return Matrix4x4(columnMajor: matrix)
        }
        let translation = node.translation ?? [0, 0, 0]
        let scale = node.scale ?? [1, 1, 1]
        let rotation = node.rotation ?? [0, 0, 0, 1]
        guard translation.count == 3, scale.count == 3, rotation.count == 4,
              (translation + scale + rotation).allSatisfy(\.isFinite) else {
            throw .malformed("Invalid glTF TRS transform", offset: nil)
        }
        return Matrix4x4(translation: SIMD3(translation[0], translation[1], translation[2]))
            * Matrix4x4(rotation: Quaternion(ix: rotation[0], iy: rotation[1], iz: rotation[2], r: rotation[3]))
            * Matrix4x4(scale: SIMD3(scale[0], scale[1], scale[2]))
    }

    func geometry(_ primitive: GLTFDocument.Primitive, materials: [Material]) throws(SceneFormatError) -> Geometry {
        guard let positionIndex = primitive.attributes["POSITION"] else { throw .malformed("Missing POSITION", offset: nil) }
        let position = try storage.accessor(positionIndex)
        guard position.definition.type == "VEC3", position.definition.componentType == 5126 else {
            throw .malformed("POSITION must contain float VEC3 values", offset: nil)
        }
        let count = position.definition.count
        var streams: [VertexStream] = []
        for (name, accessorIndex) in primitive.attributes.sorted(by: { $0.key < $1.key }) {
            let semantic: VertexSemantic
            let dimensions: [String]
            switch name {
            case "POSITION": semantic = .position; dimensions = ["VEC3"]
            case "NORMAL": semantic = .normal; dimensions = ["VEC3"]
            case "TANGENT": semantic = .tangent; dimensions = ["VEC4"]
            case "COLOR_0": semantic = .color; dimensions = ["VEC3", "VEC4"]
            case "JOINTS_0": semantic = .jointIndices; dimensions = ["VEC4"]
            case "WEIGHTS_0": semantic = .jointWeights; dimensions = ["VEC4"]
            default:
                if name.hasPrefix("TEXCOORD_"), let channel = Int(name.dropFirst(9)), channel >= 0 {
                    semantic = .textureCoordinate(channel); dimensions = ["VEC2"]
                } else if name.hasPrefix("_") { continue }
                else { throw .unsupported("glTF vertex attribute \(name)") }
            }
            let accessor = try storage.accessor(accessorIndex)
            guard accessor.definition.count == count, dimensions.contains(accessor.definition.type) else {
                throw .malformed("Mismatched vertex attribute", offset: nil)
            }
            if semantic == .jointIndices {
                guard [5121, 5123].contains(accessor.definition.componentType), accessor.definition.normalized != true else {
                    throw .malformed("Invalid joint index accessor", offset: nil)
                }
            }
            streams.append(VertexStream(semantic: semantic, componentCount: accessor.values.count / count,
                                        data: accessor.values.map(Float.init)))
        }
        var indices: [Int]
        if let index = primitive.indices {
            let accessor = try storage.accessor(index)
            guard accessor.definition.type == "SCALAR", [5121, 5123, 5125].contains(accessor.definition.componentType),
                  accessor.definition.normalized != true, accessor.values.allSatisfy({ $0 >= 0 && $0 < Double(count) }) else {
                throw .malformed("Invalid primitive indices", offset: nil)
            }
            indices = accessor.values.map(Int.init)
        } else { indices = Array(0..<count) }
        let topology: PrimitiveType
        switch primitive.mode ?? 4 {
        case 0: topology = .points
        case 1:
            guard indices.count % 2 == 0 else { throw .malformed("Incomplete lines", offset: nil) }
            topology = .lines
        case 2:
            if let first = indices.first { indices.append(first) }
            topology = .lineStrip
        case 3: topology = .lineStrip
        case 4:
            guard indices.count % 3 == 0 else { throw .malformed("Incomplete triangles", offset: nil) }
            topology = .triangles
        case 5: topology = .triangleStrip
        case 6:
            guard indices.count >= 3 else { throw .malformed("Incomplete triangle fan", offset: nil) }
            indices = (1..<indices.count - 1).flatMap { [indices[0], indices[$0], indices[$0 + 1]] }
            topology = .triangles
        default: throw .malformed("Invalid primitive topology", offset: nil)
        }
        var mesh = MeshBuffer(vertexCount: count, streams: streams, indices: IndexBuffer(indices),
                              submeshes: [Submesh(primitive: topology, range: 0..<indices.count, materialIndex: 0)])
        if mesh.stream(.normal) == nil && (topology == .triangles || topology == .triangleStrip) {
            // Generate smooth normals when the file does not supply any.
            var normals = [SIMD3<Float>](repeating: .zero, count: count)
            let points = mesh.positions
            for triangle in mesh.triangles(in: mesh.submeshes[0]) {
                let n = (points[triangle.y] - points[triangle.x]).cross(points[triangle.z] - points[triangle.x])
                for index in [triangle.x, triangle.y, triangle.z] { normals[index] += n }
            }
            mesh.streams.append(VertexStream(semantic: .normal, vectors: normals.map { $0.normalized }))
        }
        let material: Material
        if let index = primitive.material {
            guard materials.indices.contains(index) else { throw .malformed("Invalid material index", offset: nil) }
            material = materials[index]
        } else { material = Material(.physicallyBased(baseColor: [1, 1, 1, 1], metalness: 1, roughness: 1)) }
        return Geometry(mesh: mesh, materials: [material])
    }

    func camera(_ source: GLTFDocument.Camera) throws(SceneFormatError) -> Camera {
        var descriptor = CameraDescriptor()
        if source.type == "perspective", let perspective = source.perspective {
            guard perspective.yfov > 0, perspective.yfov < .pi, perspective.znear > 0,
                  perspective.zfar.map({ $0 > perspective.znear }) ?? true else {
                throw .malformed("Invalid perspective camera", offset: nil)
            }
            descriptor.fieldOfView = perspective.yfov * 180 / .pi
            descriptor.aspectRatio = perspective.aspectRatio
            descriptor.zNear = perspective.znear
            descriptor.zFar = perspective.zfar ?? 100_000
        } else if source.type == "orthographic", let orthographic = source.orthographic {
            guard orthographic.xmag > 0, orthographic.ymag > 0, orthographic.zfar > orthographic.znear else {
                throw .malformed("Invalid orthographic camera", offset: nil)
            }
            descriptor.usesOrthographicProjection = true
            descriptor.orthographicScale = orthographic.ymag
            descriptor.aspectRatio = orthographic.xmag / orthographic.ymag
            descriptor.zNear = orthographic.znear
            descriptor.zFar = orthographic.zfar
        } else { throw .malformed("Invalid glTF camera", offset: nil) }
        return Camera(descriptor)
    }

    func material(_ source: GLTFDocument.Material) throws(SceneFormatError) -> Material {
        let pbr = source.pbrMetallicRoughness
        let base = pbr?.baseColorFactor ?? [1, 1, 1, 1]
        let emission = source.emissiveFactor ?? [0, 0, 0]
        guard base.count == 4, emission.count == 3 else { throw .malformed("Invalid material color", offset: nil) }
        var material = MaterialDescriptor.physicallyBased(baseColor: SIMD4(base[0], base[1], base[2], base[3]),
                                                         metalness: pbr?.metallicFactor ?? 1, roughness: pbr?.roughnessFactor ?? 1)
        if source.extensions?.KHR_materials_unlit != nil { material.lightingModel = .unlit }
        material.name = source.name
        material.isDoubleSided = source.doubleSided ?? false
        material.emission = .color(SIMD4(emission[0], emission[1], emission[2], 1))
        if let texture = pbr?.baseColorTexture {
            material.diffuse = try textureProperty(texture)
            material.diffuseFactor = SIMD4(base[0], base[1], base[2], base[3])
        }
        if let texture = pbr?.metallicRoughnessTexture {
            material.metalness = try textureProperty(texture)
            material.roughness = material.metalness
            material.metalnessFactor = pbr?.metallicFactor ?? 1
            material.roughnessFactor = pbr?.roughnessFactor ?? 1
        }
        if let texture = source.normalTexture { material.normal = try textureProperty(texture) }
        if let texture = source.occlusionTexture { material.ambientOcclusion = try textureProperty(texture) }
        if let texture = source.emissiveTexture {
            material.emission = try textureProperty(texture)
            material.emissionFactor = SIMD3(emission[0], emission[1], emission[2])
        }
        switch source.alphaMode ?? "OPAQUE" {
        case "OPAQUE": material.alphaMode = .opaque
        case "MASK": material.alphaMode = .mask(cutoff: source.alphaCutoff ?? 0.5)
        case "BLEND": material.alphaMode = .blend
        default: throw .malformed("Unknown alpha mode", offset: nil)
        }
        return Material(material)
    }

    func textureProperty(_ info: GLTFDocument.TextureInfo) throws(SceneFormatError) -> MaterialProperty {
        guard (0...1).contains(info.texCoord ?? 0) else { throw .unsupported("Texture coordinate channels beyond 1") }
        let textures = document.textures ?? []
        let images = document.images ?? []
        guard textures.indices.contains(info.index), let imageIndex = textures[info.index].source,
              images.indices.contains(imageIndex) else { throw .malformed("Invalid texture source", offset: nil) }
        let source = images[imageIndex]
        let bytes: [UInt8]
        if let uri = source.uri { bytes = try GLTFStorage.resource(uri, loader: decoder.resourceLoader) }
        else if let view = source.bufferView { bytes = try storage.view(view).bytes }
        else { throw .malformed("Image has no data", offset: nil) }
        let image: ImageBuffer
        if PNGDecoder.isPNG(bytes) || bytes.starts(with: [0xff, 0xd8]) {
            image = try TextureImageLoader.decodeImage(bytes)
        } else if let imageDecoder = decoder.imageDecoder {
            do { image = try imageDecoder(bytes, source.mimeType) }
            catch { throw .malformed("Cannot decode image: \(error)", offset: nil) }
        } else { throw .unsupported("Image format requires an imageDecoder") }
        var sampler = TextureSampler(wrapS: .repeat, wrapT: .repeat, mipFilter: .linear)
        if let index = textures[info.index].sampler {
            let samplers = document.samplers ?? []
            guard samplers.indices.contains(index) else { throw .malformed("Invalid sampler index", offset: nil) }
            let source = samplers[index]
            func wrap(_ value: Int?) throws(SceneFormatError) -> TextureWrapMode {
                switch value ?? 10497 {
                case 10497: .repeat
                case 33071: .clamp
                case 33648: .mirror
                default: throw .malformed("Invalid texture wrap mode", offset: nil)
                }
            }
            sampler.wrapS = try wrap(source.wrapS)
            sampler.wrapT = try wrap(source.wrapT)
            guard source.magFilter.map({ [9728, 9729].contains($0) }) ?? true,
                  source.minFilter.map({ [9728, 9729, 9984, 9985, 9986, 9987].contains($0) }) ?? true else {
                throw .malformed("Invalid texture filter", offset: nil)
            }
            sampler.magnificationFilter = source.magFilter == 9728 ? .nearest : .linear
            sampler.minificationFilter = [9728, 9984, 9986].contains(source.minFilter ?? 9987) ? .nearest : .linear
            sampler.mipFilter = [9728, 9729].contains(source.minFilter ?? 9987) ? .none
                : [9984, 9985].contains(source.minFilter ?? 9987) ? .nearest : .linear
        }
        return MaterialProperty(.texture(.image(image)), intensity: info.scale ?? info.strength ?? 1,
                                sampler: sampler, mappingChannel: info.texCoord ?? 0)
    }
}
