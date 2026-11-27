import SceneCore
import SceneGraph

/// Plays a glTF animation and updates CPU-skinned meshes. Access it through Scene.systems.
/// The first clip plays by default; set animationIndex to nil to stop animation while retaining skinning.
public final class GLTFSceneRuntime: SceneSystem {
    public var animationIndex: Int? = 0
    public var loops = true
    public var speed: Float = 1
    public var time: Float = 0
    public let animationNames: [String]

    private struct Track {
        var node: Node
        var path: String
        var times: [Float]
        var values: [Float]
        var components: Int
        var interpolation: String

        func sample(_ time: Float) -> [Float] {
            let cubic = interpolation == "CUBICSPLINE"
            let stride = components * (cubic ? 3 : 1)
            func value(_ key: Int) -> [Float] {
                Array(values[key * stride + (cubic ? components : 0)..<key * stride + (cubic ? 2 * components : components)])
            }
            if time <= times[0] { return value(0) }
            if time >= times[times.count - 1] { return value(times.count - 1) }
            var low = 0, high = times.count - 1
            while high - low > 1 {
                let middle = (low + high) / 2
                if times[middle] <= time { low = middle } else { high = middle }
            }
            let a = value(low), b = value(high)
            if interpolation == "STEP" { return a }
            let span = times[high] - times[low]
            let t = (time - times[low]) / span
            if cubic {
                let t2 = t * t, t3 = t2 * t
                return (0..<components).map {
                    let outTangent = values[low * stride + 2 * components + $0] * span
                    let inTangent = values[high * stride + $0] * span
                    return (2 * t3 - 3 * t2 + 1) * a[$0] + (t3 - 2 * t2 + t) * outTangent
                        + (-2 * t3 + 3 * t2) * b[$0] + (t3 - t2) * inTangent
                }
            }
            if path == "rotation" {
                let qa = Quaternion(vector: SIMD4(a[0], a[1], a[2], a[3]))
                let qb = Quaternion(vector: SIMD4(b[0], b[1], b[2], b[3]))
                let q = Quaternion.slerp(from: qa, to: qb, t: t).vector
                return [q.x, q.y, q.z, q.w]
            }
            return zip(a, b).map { $0 + ($1 - $0) * t }
        }
    }
    private struct Deformation {
        var node: Node
        var owner: Node
        var base: MeshBuffer
        var joints: [Node]
        var inverseBinds: [Matrix4x4]
        var morphs: [[VertexSemantic: [Float]]]
        var weights: [Float]
    }
    private var clips: [[Track]] = []
    private var initialTransforms: [(Node, LocalTransform)] = []
    private var previousAnimation: Int?
    private var deformations: [Deformation] = []
    private var morphWeights: [ObjectIdentifier: [Float]] = [:]

    init(storage: GLTFStorage, nodes: [Node], primitiveNodes: [[Node]]) throws(SceneFormatError) {
        let document = storage.document
        let definitions = document.nodes ?? []
        initialTransforms = nodes.map { ($0, $0.localTransform) }
        animationNames = (document.animations ?? []).enumerated().map { $0.element.name ?? "Animation \($0.offset + 1)" }
        for (index, definition) in definitions.enumerated() {
            guard let meshIndex = definition.mesh else { continue }
            let meshDefinitions = document.meshes ?? []
            guard meshDefinitions.indices.contains(meshIndex) else { throw .malformed("Invalid mesh", offset: nil) }
            let mesh = meshDefinitions[meshIndex]
            var joints: [Node] = []
            var inverseBinds: [Matrix4x4] = []
            if let skinIndex = definition.skin {
                let skins = document.skins ?? []
                guard skins.indices.contains(skinIndex), !skins[skinIndex].joints.isEmpty else {
                    throw .malformed("Invalid skin index", offset: nil)
                }
                let skin = skins[skinIndex]
                guard Set(skin.joints).count == skin.joints.count,
                      skin.joints.allSatisfy({ nodes.indices.contains($0) }) else {
                    throw .malformed("Invalid skin joints", offset: nil)
                }
                joints = skin.joints.map { nodes[$0] }
                if let accessor = skin.inverseBindMatrices {
                    let data = try storage.accessor(accessor)
                    guard data.definition.type == "MAT4", data.definition.componentType == 5126,
                          data.definition.count == joints.count else {
                        throw .malformed("Invalid inverse bind matrices", offset: nil)
                    }
                    inverseBinds = (0..<joints.count).map {
                        Matrix4x4(columnMajor: data.values[$0 * 16..<($0 + 1) * 16].map(Float.init))
                    }
                } else { inverseBinds = Array(repeating: .identity, count: joints.count) }
            }
            for (primitiveIndex, primitive) in mesh.primitives.enumerated() {
                let node = primitiveNodes[index][primitiveIndex]
                guard let geometry = node.geometry else { continue }
                let base = geometry.mesh
                if !joints.isEmpty {
                    guard let indices = base.stream(.jointIndices), let weights = base.stream(.jointWeights),
                          indices.componentCount == 4, weights.componentCount == 4,
                          indices.data.allSatisfy({ $0 >= 0 && $0 < Float(joints.count) && $0.rounded() == $0 }),
                          weights.data.allSatisfy({ $0 >= 0 && $0.isFinite }) else {
                        throw .malformed("Invalid skin weights or joint indices", offset: nil)
                    }
                    for vertex in 0..<base.vertexCount {
                        guard weights[vertex].reduce(0, +) > 0 else { throw .malformed("Zero skin weights", offset: nil) }
                    }
                }
                var morphs: [[VertexSemantic: [Float]]] = []
                for target in primitive.targets ?? [] {
                    var streams: [VertexSemantic: [Float]] = [:]
                    for (semantic, accessor) in target {
                        let key: VertexSemantic
                        switch semantic {
                        case "POSITION": key = .position
                        case "NORMAL": key = .normal
                        case "TANGENT": key = .tangent
                        default: throw .unsupported("Morph target \(semantic)")
                        }
                        let data = try storage.accessor(accessor)
                        guard data.definition.type == "VEC3", data.definition.componentType == 5126,
                              data.definition.count == base.vertexCount, base.stream(key) != nil else {
                            throw .malformed("Invalid morph target accessor", offset: nil)
                        }
                        streams[key] = data.values.map(Float.init)
                    }
                    morphs.append(streams)
                }
                if let weights = definition.weights ?? mesh.weights,
                   weights.count != morphs.count || !weights.allSatisfy(\.isFinite) {
                    throw .malformed("Invalid morph weights", offset: nil)
                }
                if !joints.isEmpty || !morphs.isEmpty {
                    deformations.append(Deformation(node: node, owner: nodes[index], base: base,
                        joints: joints, inverseBinds: inverseBinds, morphs: morphs,
                        weights: definition.weights ?? mesh.weights ?? Array(repeating: 0, count: morphs.count)))
                }
            }
        }
        for animation in document.animations ?? [] {
            var tracks: [Track] = []
            var destinations: Set<String> = []
            for channel in animation.channels {
                guard let nodeIndex = channel.target.node, nodes.indices.contains(nodeIndex),
                      animation.samplers.indices.contains(channel.sampler),
                      destinations.insert("\(nodeIndex):\(channel.target.path)").inserted else {
                    throw .malformed("Invalid or duplicate animation channel", offset: nil)
                }
                let sampler = animation.samplers[channel.sampler]
                let input = try storage.accessor(sampler.input)
                let output = try storage.accessor(sampler.output)
                let times = input.values.map(Float.init)
                guard input.definition.type == "SCALAR", input.definition.componentType == 5126,
                      output.definition.componentType == 5126, times[0] >= 0,
                      zip(times, times.dropFirst()).allSatisfy({ $0 < $1 }) else {
                    throw .malformed("Invalid animation time or value accessor", offset: nil)
                }
                let interpolation = sampler.interpolation ?? "LINEAR"
                guard ["LINEAR", "STEP", "CUBICSPLINE"].contains(interpolation) else {
                    throw .unsupported("Animation interpolation \(interpolation)")
                }
                let path = channel.target.path
                let components: Int
                switch path {
                case "translation", "scale": components = 3
                case "rotation": components = 4
                case "weights":
                    components = deformations.first { $0.owner === nodes[nodeIndex] }?.morphs.count ?? 0
                default: throw .unsupported("Animation path \(path)")
                }
                guard definitions[nodeIndex].matrix == nil,
                      output.definition.type == (path == "weights" ? "SCALAR" : components == 4 ? "VEC4" : "VEC3"),
                      components > 0, output.values.count == times.count * components * (interpolation == "CUBICSPLINE" ? 3 : 1) else {
                    throw .malformed("Animation output count mismatch", offset: nil)
                }
                tracks.append(Track(node: nodes[nodeIndex], path: path, times: times,
                                    values: output.values.map(Float.init), components: components, interpolation: interpolation))
            }
            clips.append(tracks)
        }
    }

    public func update(_ scene: Scene, by delta: Duration) {
        guard time.isFinite, speed.isFinite else { return }
        time += Float(delta.components.seconds) * speed + Float(delta.components.attoseconds) / 1e18 * speed
        guard time.isFinite else { return }
        if let index = animationIndex, clips.indices.contains(index) {
            if previousAnimation != index {
                for (node, transform) in initialTransforms { node.localTransform = transform }
                morphWeights.removeAll()
                previousAnimation = index
            }
            let tracks = clips[index]
            let duration = tracks.compactMap { $0.times.last }.max() ?? 0
            let sampleTime = loops && duration > 0 ? max(time, 0).truncatingRemainder(dividingBy: duration) : max(time, 0)
            for track in tracks {
                let value = track.sample(sampleTime)
                switch track.path {
                case "translation": track.node.position = SIMD3(value[0], value[1], value[2])
                case "scale": track.node.scale = SIMD3(value[0], value[1], value[2])
                case "rotation": track.node.orientation = Quaternion(vector: SIMD4(value[0], value[1], value[2], value[3])).normalized
                case "weights": morphWeights[ObjectIdentifier(track.node)] = value
                default: break
                }
            }
        }
        for deformation in deformations {
            var mesh = deformation.base
            let weights = morphWeights[ObjectIdentifier(deformation.owner)] ?? deformation.weights
            for (target, weight) in zip(deformation.morphs, weights) {
                for (semantic, deltas) in target {
                    guard let index = mesh.streams.firstIndex(where: { $0.semantic == semantic }) else { continue }
                    let stride = mesh.streams[index].componentCount
                    for vertex in 0..<mesh.vertexCount {
                        for axis in 0..<3 { mesh.streams[index].data[vertex * stride + axis] += deltas[vertex * 3 + axis] * weight }
                    }
                }
            }
            if !deformation.joints.isEmpty, let inverse = deformation.node.worldTransform.inverse,
               let indices = mesh.stream(.jointIndices), let weights = mesh.stream(.jointWeights) {
                let matrices = zip(deformation.joints, deformation.inverseBinds).map { inverse * $0.worldTransform * $1 }
                for semantic in [VertexSemantic.position, .normal, .tangent] {
                    guard let streamIndex = mesh.streams.firstIndex(where: { $0.semantic == semantic }) else { continue }
                    let source = mesh.streams[streamIndex]
                    for vertex in 0..<mesh.vertexCount {
                        let values = Array(source[vertex])
                        let value = SIMD3(values[0], values[1], values[2])
                        var result = SIMD3<Float>.zero
                        let sum = weights[vertex].reduce(0, +)
                        for component in 0..<4 {
                            let joint = Int(indices.data[vertex * 4 + component])
                            let weight = weights.data[vertex * 4 + component] / sum
                            let matrix = matrices[joint]
                            result += (semantic == .position ? matrix.transformPoint(value)
                                : (semantic == .normal ? (matrix.inverse?.transpose ?? matrix) : matrix).transformDirection(value)) * weight
                        }
                        if semantic != .position { result = result.normalized }
                        for axis in 0..<3 { mesh.streams[streamIndex].data[vertex * source.componentCount + axis] = result[axis] }
                    }
                }
            }
            mesh.bounds = BoundingBox(points: mesh.positions)
            deformation.node.geometry?.source = .mesh(mesh)
        }
    }
}
