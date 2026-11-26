/// What a vertex stream holds.
public enum VertexSemantic: Hashable, Sendable {
    case position
    case normal
    case tangent
    case bitangent
    case color
    /// Texture coordinates; channel 0 first.
    case textureCoordinate(Int)
    case jointIndices
    case jointWeights
    case custom(String)
}

/// One attribute of every vertex, planar: `componentCount` floats a vertex, one vertex after another.
public struct VertexStream: Hashable, Sendable {

    public var semantic: VertexSemantic

    public var componentCount: Int

    public var data: [Float]

    public init(semantic: VertexSemantic, componentCount: Int, data: [Float]) {
        precondition(componentCount > 0 && data.count % componentCount == 0, "A stream's data is whole vertices")
        self.semantic = semantic
        self.componentCount = componentCount
        self.data = data
    }

    public init(semantic: VertexSemantic, vectors: [SIMD2<Float>]) {
        self.init(semantic: semantic, componentCount: 2, data: vectors.flatMap { [$0.x, $0.y] })
    }

    public init(semantic: VertexSemantic, vectors: [SIMD3<Float>]) {
        self.init(semantic: semantic, componentCount: 3, data: vectors.flatMap { [$0.x, $0.y, $0.z] })
    }

    public init(semantic: VertexSemantic, vectors: [SIMD4<Float>]) {
        self.init(semantic: semantic, componentCount: 4, data: vectors.flatMap { [$0.x, $0.y, $0.z, $0.w] })
    }

    public var vertexCount: Int { data.count / componentCount }

    /// The vertex's components.
    public subscript(vertex: Int) -> ArraySlice<Float> {
        data[vertex * componentCount ..< (vertex + 1) * componentCount]
    }
}

/// How a run of vertices or indices makes primitives.
public enum PrimitiveType: Hashable, Sendable {
    case triangles
    case triangleStrip
    case lines
    case lineStrip
    case points
}

/// A mesh's indices.
public enum IndexBuffer: Hashable, Sendable {
    case uint16([UInt16])
    case uint32([UInt32])

    /// The smallest buffer for the indices.
    public init(_ indices: [Int]) {
        if (indices.max() ?? 0) <= Int(UInt16.max) {
            self = .uint16(indices.map { UInt16($0) })
        } else {
            self = .uint32(indices.map { UInt32($0) })
        }
    }

    public var count: Int {
        switch self {
        case .uint16(let indices): indices.count
        case .uint32(let indices): indices.count
        }
    }

    public subscript(position: Int) -> Int {
        switch self {
        case .uint16(let indices): Int(indices[position])
        case .uint32(let indices): Int(indices[position])
        }
    }
}

/// A run of a mesh drawn with one material.
public struct Submesh: Hashable, Sendable {

    public var primitive: PrimitiveType

    /// Positions in the index buffer when the mesh has one, else vertices.
    public var range: Range<Int>

    /// Which of the materials the run is drawn with; past the end, they repeat.
    public var materialIndex: Int

    public var name: String?

    public init(primitive: PrimitiveType = .triangles, range: Range<Int>, materialIndex: Int, name: String? = nil) {
        self.primitive = primitive
        self.range = range
        self.materialIndex = materialIndex
        self.name = name
    }
}

/// A mesh's vertices and how they are drawn, ready for any renderer: planar vertex streams, optional indices,
/// runs of primitives each with its own material, and the bounds.
public struct MeshBuffer: Hashable, Sendable {

    public var vertexCount: Int

    public var streams: [VertexStream]

    public var indices: IndexBuffer?

    public var submeshes: [Submesh]

    public var bounds: BoundingBox

    /// A mesh; the bounds are the positions' when not given.
    public init(
        vertexCount: Int,
        streams: [VertexStream],
        indices: IndexBuffer? = nil,
        submeshes: [Submesh],
        bounds: BoundingBox? = nil
    ) {
        precondition(streams.allSatisfy { $0.vertexCount == vertexCount }, "Every stream has every vertex")
        self.vertexCount = vertexCount
        self.streams = streams
        self.indices = indices
        self.submeshes = submeshes
        self.bounds = .empty
        self.bounds = bounds ?? BoundingBox(points: positions)
    }

    public static let empty = MeshBuffer(vertexCount: 0, streams: [], submeshes: [])

    public func stream(_ semantic: VertexSemantic) -> VertexStream? {
        streams.first { $0.semantic == semantic }
    }

    public var positions: [SIMD3<Float>] {
        guard let stream = stream(.position), stream.componentCount >= 3 else { return [] }
        return (0..<vertexCount).map { i in
            let base = i * stream.componentCount
            return SIMD3(stream.data[base], stream.data[base + 1], stream.data[base + 2])
        }
    }

    /// The vertex a submesh's `position` names, through the indices when there are some.
    public func vertex(at position: Int) -> Int {
        indices?[position] ?? position
    }

    /// A submesh's triangles as vertex numbers; empty for lines and points.
    public func triangles(in submesh: Submesh) -> [SIMD3<Int>] {
        let range = submesh.range
        switch submesh.primitive {
        case .triangles:
            return stride(from: range.lowerBound, to: range.upperBound - 2, by: 3).map {
                SIMD3(vertex(at: $0), vertex(at: $0 + 1), vertex(at: $0 + 2))
            }
        case .triangleStrip:
            guard range.count >= 3 else { return [] }
            return (range.lowerBound ..< range.upperBound - 2).map { i in
                // Every other triangle is wound the other way round.
                let odd = (i - range.lowerBound) % 2 == 1
                return SIMD3(vertex(at: i), vertex(at: odd ? i + 2 : i + 1), vertex(at: odd ? i + 1 : i + 2))
            }
        case .lines, .lineStrip, .points:
            return []
        }
    }

    /// The vertices interleaved, in the order of `streams`.
    public func interleaved() -> InterleavedVertices {
        var attributes: [InterleavedVertices.Attribute] = []
        var stride = 0
        for stream in streams {
            attributes.append(.init(semantic: stream.semantic, offset: stride, componentCount: stream.componentCount))
            stride += stream.componentCount
        }
        var data = [Float]()
        data.reserveCapacity(stride * vertexCount)
        for vertex in 0..<vertexCount {
            for stream in streams {
                data.append(contentsOf: stream[vertex])
            }
        }
        return InterleavedVertices(attributes: attributes, stride: stride, data: data)
    }
}

/// Vertices with all their attributes together, as a GPU buffer wants them.
public struct InterleavedVertices: Hashable, Sendable {

    public struct Attribute: Hashable, Sendable {
        public var semantic: VertexSemantic
        /// Where in a vertex the attribute starts, in floats.
        public var offset: Int
        public var componentCount: Int
    }

    public var attributes: [Attribute]

    /// The floats a vertex.
    public var stride: Int

    public var data: [Float]
}
