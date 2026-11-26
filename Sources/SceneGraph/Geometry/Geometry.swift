import SceneCore

/// What a node shows: a mesh, built-in or given, and its materials, one for each of the mesh's submeshes.
/// A geometry may be shared by any number of nodes.
public final class Geometry {

    /// Where the geometry's mesh comes from.
    public enum Source: Hashable, Sendable {
        case primitive(Primitive)
        case mesh(MeshBuffer)
    }

    public var name: String?

    public var source: Source {
        didSet {
            cachedMesh = nil
            key.revision &+= 1
        }
    }

    /// The materials; the default material when none are set.
    public var materials: [Material] {
        get {
            if storedMaterials.isEmpty { storedMaterials = [Material()] }
            return storedMaterials
        }
        set { storedMaterials = newValue }
    }

    /// Identifies the mesh for a backend's buffers; the revision changes with the source.
    public private(set) var key = ResourceKey.unique()

    private var storedMaterials: [Material]

    private var cachedMesh: MeshBuffer?

    public init(_ source: Source, materials: [Material] = []) {
        self.source = source
        self.storedMaterials = materials
    }

    public convenience init(_ primitive: Primitive, materials: [Material] = []) {
        self.init(.primitive(primitive), materials: materials)
    }

    public convenience init(mesh: MeshBuffer, materials: [Material] = []) {
        self.init(.mesh(mesh), materials: materials)
    }

    /// The mesh, built once for a primitive.
    public var mesh: MeshBuffer {
        if let cachedMesh { return cachedMesh }
        let made: MeshBuffer
        switch source {
        case .primitive(let primitive): made = primitive.makeMesh()
        case .mesh(let mesh): made = mesh
        }
        cachedMesh = made
        return made
    }

    public var boundingBox: BoundingBox { mesh.bounds }

    public var firstMaterial: Material? {
        get { materials.first }
        set {
            guard let newValue else {
                storedMaterials = []
                return
            }
            var list = materials
            list[0] = newValue
            storedMaterials = list
        }
    }

    public func material(named name: String) -> Material? {
        materials.first { $0.name == name }
    }

    /// The material a submesh is drawn with; with fewer materials than that, they repeat, as SceneKit's do.
    public func material(forSubmesh index: Int) -> Material {
        let list = materials
        let submesh = mesh.submeshes.indices.contains(index) ? mesh.submeshes[index].materialIndex : index
        return list[max(submesh, 0) % list.count]
    }
}

// MARK: - Built-in shapes

public extension Geometry {

    static func box(width: Float = 1, height: Float = 1, length: Float = 1) -> Geometry {
        Geometry(.box(width: width, height: height, length: length))
    }

    static func sphere(radius: Float = 0.5, segmentCount: Int = 48) -> Geometry {
        Geometry(.sphere(radius: radius, segmentCount: segmentCount))
    }

    static func plane(width: Float = 1, height: Float = 1) -> Geometry {
        Geometry(.plane(width: width, height: height))
    }

    static func floor(width: Float = 0, length: Float = 0) -> Geometry {
        Geometry(.floor(width: width, length: length))
    }

    static func cylinder(radius: Float = 0.5, height: Float = 1, radialSegmentCount: Int = 48) -> Geometry {
        Geometry(.cylinder(radius: radius, height: height, radialSegmentCount: radialSegmentCount))
    }

    static func cone(topRadius: Float = 0, bottomRadius: Float = 0.5, height: Float = 1, radialSegmentCount: Int = 48) -> Geometry {
        Geometry(.cone(topRadius: topRadius, bottomRadius: bottomRadius, height: height, radialSegmentCount: radialSegmentCount))
    }

    static func tube(innerRadius: Float = 0.25, outerRadius: Float = 0.5, height: Float = 1, radialSegmentCount: Int = 48) -> Geometry {
        Geometry(.tube(innerRadius: innerRadius, outerRadius: outerRadius, height: height, radialSegmentCount: radialSegmentCount))
    }

    static func torus(ringRadius: Float = 0.5, pipeRadius: Float = 0.25, ringSegmentCount: Int = 48, pipeSegmentCount: Int = 24) -> Geometry {
        Geometry(.torus(ringRadius: ringRadius, pipeRadius: pipeRadius, ringSegmentCount: ringSegmentCount, pipeSegmentCount: pipeSegmentCount))
    }

    static func pyramid(width: Float = 1, height: Float = 1, length: Float = 1) -> Geometry {
        Geometry(.pyramid(width: width, height: height, length: length))
    }

    static func capsule(capRadius: Float = 0.5, height: Float = 2, radialSegmentCount: Int = 48, capSegmentCount: Int = 12) -> Geometry {
        Geometry(.capsule(capRadius: capRadius, height: height, radialSegmentCount: radialSegmentCount, capSegmentCount: capSegmentCount))
    }
}
