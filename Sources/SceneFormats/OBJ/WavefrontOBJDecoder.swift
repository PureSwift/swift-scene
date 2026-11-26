import SceneCore
import SceneGraph

/// Reads a Wavefront OBJ file into a scene.
///
/// Each object (`o`) or group (`g`) becomes a node with one geometry, its faces split into a submesh for each material
/// (`usemtl`) they use, in the order first used. Faces with more than three vertices — concave ones too — are cut
/// into triangles; faces without normals are flat. Vertices are shared where their position, texture coordinates and
/// normal are all the same. Vertex colours after a position (`v x y z r g b`), as many writers add, become a colour
/// stream. Texture coordinates flip, since OBJ's start at the bottom. Lines, points, curves and surfaces aren't read.
public struct WavefrontOBJDecoder: SceneAssetDecoder {

    public static let fileExtensions = ["obj"]

    /// Where relative paths — material libraries and their textures — are from: the OBJ file's directory.
    public var baseDirectory: String?

    /// Reads a material library (`mtllib`) by its path, resolved against `baseDirectory`; nil if it can't.
    public var materialLibraryLoader: ((String) -> [UInt8]?)?

    /// Whether a bad face or index fails the whole file; otherwise it's skipped.
    public var isStrict: Bool

    public init(baseDirectory: String? = nil, isStrict: Bool = false, materialLibraryLoader: ((String) -> [UInt8]?)? = nil) {
        self.baseDirectory = baseDirectory
        self.isStrict = isStrict
        self.materialLibraryLoader = materialLibraryLoader
    }

    public func decode(_ data: [UInt8]) async throws(SceneFormatError) -> Scene {
        try decodeScene(data)
    }

    public func decodeScene(_ data: [UInt8]) throws(SceneFormatError) -> Scene {
        var reader = OBJLineReader(data)
        var positions: [SIMD3<Float>] = []
        var colors: [SIMD3<Float>?] = []
        var textureCoordinates: [SIMD2<Float>] = []
        var normals: [SIMD3<Float>] = []
        var materials: [String: MaterialDescriptor] = [:]
        var groups: [OBJGroup] = [OBJGroup(name: nil)]
        var material: String?
        var faceCount = 0

        func fail(_ message: String) throws(SceneFormatError) {
            if isStrict { throw .malformed(message, offset: reader.lineNumber) }
        }

        func startGroup(_ name: String?) {
            if groups[groups.count - 1].isEmpty {
                groups[groups.count - 1].name = name
            } else {
                groups.append(OBJGroup(name: name))
            }
        }

        while reader.nextLine() {
            guard let keyword = reader.token() else { continue }
            switch String(decoding: keyword, as: UTF8.self) {
            case "v":
                let values = reader.numbers(upTo: 7)
                guard values.count >= 3 else {
                    try fail("A vertex needs three coordinates")
                    positions.append(.zero)
                    colors.append(nil)
                    continue
                }
                positions.append(SIMD3(values[0], values[1], values[2]))
                // Seven values are a position, w and nothing else by the standard; writers put colours in six.
                colors.append(values.count == 6 ? SIMD3(values[3], values[4], values[5]) : nil)
            case "vt":
                let values = reader.numbers(upTo: 3)
                textureCoordinates.append(SIMD2(values.first ?? 0, values.count > 1 ? values[1] : 0))
            case "vn":
                let values = reader.numbers(upTo: 3)
                normals.append(values.count == 3 ? SIMD3(values[0], values[1], values[2]) : SIMD3(0, 0, 1))
            case "f", "fo":
                var corners: [OBJCorner] = []
                var valid = true
                while let token = reader.token() {
                    guard let corner = OBJCorner(token, positions: positions.count, textureCoordinates: textureCoordinates.count, normals: normals.count) else {
                        valid = false
                        break
                    }
                    corners.append(corner)
                }
                guard valid, corners.count >= 3 else {
                    try fail("A face with a bad vertex, or fewer than three")
                    continue
                }
                groups[groups.count - 1].addFace(corners, material: material, faceIndex: faceCount, positions: positions)
                faceCount += 1
            case "o":
                startGroup(reader.rest())
            case "g":
                let name = reader.rest()
                startGroup(name.isEmpty || name == "default" ? nil : name)
            case "usemtl":
                material = reader.rest()
            case "mtllib":
                for library in reader.rest().split(separator: " ").map(String.init) {
                    let path = resolve(library)
                    guard let bytes = materialLibraryLoader?(path) else { continue }
                    let directory = path.lastIndex(of: "/").map { String(path[..<$0]) }
                    materials.merge(MTLDecoder(baseDirectory: directory).decode(bytes)) { _, new in new }
                }
            default:
                // Smoothing groups, lines, points, curves and surfaces.
                break
            }
        }

        let scene = Scene()
        for group in groups where !group.isEmpty {
            let geometry = group.makeGeometry(textureCoordinates: textureCoordinates, normals: normals, colors: colors, materials: materials)
            scene.rootNode.addChild(Node(name: group.name, geometry: geometry))
        }
        return scene
    }

    private func resolve(_ path: String) -> String {
        let path = path.replacingBackslashes()
        guard let baseDirectory, !baseDirectory.isEmpty, !path.hasPrefix("/") else { return path }
        return baseDirectory.hasSuffix("/") ? baseDirectory + path : baseDirectory + "/" + path
    }
}

// MARK: - Faces

/// A face's corner: indices into the positions, texture coordinates and normals, from 0; -1 for none.
struct OBJCorner: Hashable {
    var position: Int
    var textureCoordinate: Int
    var normal: Int

    /// `v`, `v/vt`, `v//vn` or `v/vt/vn`, counting from 1, or back from the latest with negative numbers.
    init?(_ token: ArraySlice<UInt8>, positions: Int, textureCoordinates: Int, normals: Int) {
        let parts = token.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false)
        func index(_ part: Int, count: Int) -> Int?? {
            guard part < parts.count, !parts[part].isEmpty else { return .some(nil) }
            guard let value = OBJLineReader.parseInteger(parts[part]), value != 0 else { return nil }
            let index = value > 0 ? value - 1 : count + value
            return index >= 0 && index < count ? .some(index) : nil
        }
        guard parts.count <= 3, let p = index(0, count: positions), let p,
              let t = index(1, count: textureCoordinates), let n = index(2, count: normals) else { return nil }
        position = p
        textureCoordinate = t ?? -1
        normal = n ?? -1
    }
}

/// An object or group's faces, as shared vertices and triangles for each material.
struct OBJGroup {

    var name: String?

    /// A vertex: a corner, or for faces without normals, a corner on that face.
    private struct Key: Hashable {
        var corner: OBJCorner
        var face: Int
    }

    private var vertices: [Key: Int] = [:]
    private var corners: [OBJCorner] = []
    /// The face normal for vertices of faces without normals of their own.
    private var flatNormals: [SIMD3<Float>?] = []
    private var positions: [SIMD3<Float>] = []
    /// Triangles by material, and the materials in the order first used.
    private var triangles: [String?: [Int]] = [:]
    private var materialOrder: [String?] = []

    init(name: String?) {
        self.name = name
    }

    var isEmpty: Bool { triangles.isEmpty }

    mutating func addFace(_ face: [OBJCorner], material: String?, faceIndex: Int, positions all: [SIMD3<Float>]) {
        let points = face.map { all[$0.position] }
        let hasNormals = face.allSatisfy { $0.normal >= 0 }
        let faceNormal = Triangulation.newellNormal(points)
        let cut: [SIMD3<Int>] = face.count == 3 ? [SIMD3(0, 1, 2)] : Triangulation.triangulate([points], normal: faceNormal)
        guard !cut.isEmpty else { return }
        let indices = face.enumerated().map { offset, corner -> Int in
            let key = Key(corner: corner, face: hasNormals ? -1 : faceIndex)
            if let known = vertices[key] { return known }
            let index = corners.count
            vertices[key] = index
            corners.append(corner)
            flatNormals.append(hasNormals ? nil : faceNormal)
            positions.append(points[offset])
            return index
        }
        if triangles[material] == nil { materialOrder.append(material) }
        for t in cut {
            triangles[material, default: []] += [indices[t.x], indices[t.y], indices[t.z]]
        }
    }

    func makeGeometry(
        textureCoordinates: [SIMD2<Float>],
        normals: [SIMD3<Float>],
        colors: [SIMD3<Float>?],
        materials library: [String: MaterialDescriptor]
    ) -> Geometry {
        var streams = [
            VertexStream(semantic: .position, vectors: positions),
            VertexStream(semantic: .normal, vectors: corners.indices.map { i in
                corners[i].normal >= 0 ? normals[corners[i].normal].normalized : flatNormals[i] ?? SIMD3(0, 0, 1)
            }),
        ]
        if corners.contains(where: { $0.textureCoordinate >= 0 }) {
            streams.append(VertexStream(semantic: .textureCoordinate(0), vectors: corners.map { corner in
                guard corner.textureCoordinate >= 0 else { return .zero }
                let uv = textureCoordinates[corner.textureCoordinate]
                return SIMD2(uv.x, 1 - uv.y)
            }))
        }
        let hasColors = corners.contains { colors[$0.position] != nil }
        if hasColors {
            streams.append(VertexStream(semantic: .color, vectors: corners.map { SIMD4(colors[$0.position] ?? SIMD3(repeating: 1), 1) }))
        }
        var indices: [Int] = []
        var submeshes: [Submesh] = []
        var materials: [Material] = []
        for name in materialOrder {
            let run = triangles[name] ?? []
            submeshes.append(Submesh(range: indices.count ..< indices.count + run.count, materialIndex: materials.count, name: name))
            indices += run
            var descriptor = name.flatMap { library[$0] } ?? MaterialDescriptor(name: name, lightingModel: .phong)
            // Vertex colours are the colour; a plain diffuse colour would only darken them.
            if hasColors, case .color = descriptor.diffuse.contents { descriptor.diffuse = .color(SIMD4(1, 1, 1, 1)) }
            materials.append(Material(descriptor))
        }
        let mesh = MeshBuffer(vertexCount: positions.count, streams: streams, indices: IndexBuffer(indices), submeshes: submeshes)
        return Geometry(mesh: mesh, materials: materials)
    }
}
