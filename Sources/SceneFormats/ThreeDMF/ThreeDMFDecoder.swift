// Ported from Quesa's 3DMF object readers (E3FFR_3DMF_Geometry.cpp, E3FFR_3DMF.cpp).
// Copyright (c) 1999-2021, Quesa Developers. All rights reserved.
// Licensed under the BSD 3-Clause License; see LICENSE-Quesa.

import SceneCore
import SceneGraph

/// Reads a 3D Metafile, binary or text, into a scene.
///
/// The objects are submitted in order as QuickDraw 3D would draw them: transforms, attribute sets and shaders
/// change the state for what follows in the same group; each group is a node, its state its own; each geometry
/// is a node placed by the transforms before it. Geometry is TriMesh, Triangle, Polygon, Box and the quadrics
/// (Ellipsoid, Cone, Cylinder, Disk, Torus) so far; other objects are skipped.
public struct ThreeDMFDecoder: SceneAssetDecoder {

    public static let fileExtensions = ["3dmf", "3dm", "q3d"]

    /// Whether an object that can't be read fails the whole file; otherwise it is skipped.
    public var isStrict: Bool

    public init(isStrict: Bool = false) {
        self.isStrict = isStrict
    }

    public func decode(_ data: [UInt8]) async throws(SceneFormatError) -> Scene {
        try decodeScene(data)
    }

    public func decodeScene(_ data: [UInt8]) throws(SceneFormatError) -> Scene {
        try decodeScene(Metafile3D(data))
    }

    public func decodeScene(_ metafile: Metafile3D) throws(SceneFormatError) -> Scene {
        let scene = Scene()
        var state = State()
        try submit(metafile.objects, to: scene.rootNode, state: &state)
        return scene
    }

    // MARK: State

    /// What QuickDraw 3D's view keeps while a group is drawn.
    struct State {
        var transform = Matrix4x4.identity
        var attributes = Attributes()
        var lightingModel: LightingModel?
        var subdivision = Subdivision.default
    }

    /// How finely curved surfaces are cut into triangles.
    enum Subdivision {
        /// So many segments round (u) and along (v).
        case constant(u: Int, v: Int)
        /// A segment for every so much length, in world space.
        case worldSpace(Float)

        /// Quesa's fallback, since it draws QuickDraw 3D's default screen-space style this way.
        static let `default` = Subdivision.constant(u: 16, v: 8)
    }

    /// An attribute set's values; nil for those it doesn't set.
    struct Attributes {
        var diffuse: SIMD3<Float>?
        var specular: SIMD3<Float>?
        var specularControl: Float?
        var transparency: SIMD3<Float>?
        var emissive: SIMD3<Float>?
        var metallic: Float?
        var texture: ImageBuffer?
        var name: String?

        /// These attributes over `base`.
        func over(_ base: Attributes) -> Attributes {
            Attributes(
                diffuse: diffuse ?? base.diffuse,
                specular: specular ?? base.specular,
                specularControl: specularControl ?? base.specularControl,
                transparency: transparency ?? base.transparency,
                emissive: emissive ?? base.emissive,
                metallic: metallic ?? base.metallic,
                texture: texture ?? base.texture,
                name: name
            )
        }
    }

    // MARK: Submitting

    private func submit(_ objects: [MetafileObject], to parent: Node, state: inout State) throws(SceneFormatError) {
        for object in objects {
            do {
                try submit(object, to: parent, state: &state)
            } catch {
                if isStrict { throw error }
            }
        }
    }

    private func submit(_ object: MetafileObject, to parent: Node, state: inout State) throws(SceneFormatError) {
        switch object.type {
        case .group, .displayGroup, .orderedDisplayGroup, .ioProxyDisplayGroup, .lightGroup, .infoGroup:
            // A group draws with its own copy of the state, from where it is.
            let node = Node()
            node.transform = state.transform
            node.name = Self.name(in: object.children)
            parent.addChild(node)
            var inner = state
            inner.transform = .identity
            try submit(object.children.filter { $0.type != .displayGroupState && $0.type != .displayGroupBoundingBox }, to: node, state: &inner)
        case .matrixTransform, .scaleTransform, .translateTransform, .rotateTransform,
             .rotateAboutPointTransform, .rotateAboutAxisTransform, .quaternionTransform:
            state.transform = state.transform * (try Self.transform(object))
        case .resetTransform:
            state.transform = .identity
        case .attributeSet:
            state.attributes = try attributes(object).over(state.attributes)
        case .textureShader:
            state.attributes.texture = try texture(object) ?? state.attributes.texture
        case .phongIllumination:
            state.lightingModel = .phong
        case .lambertIllumination:
            state.lightingModel = .lambert
        case .nullIllumination, .nondirectionalIllumination:
            state.lightingModel = .unlit
        case .subdivisionStyle:
            var r = object.reader()
            let method = try r.enumerated(["constant": 0, "worldspace": 1, "screenspace": 2])
            let c1 = try r.float32()
            let c2 = r.isAtEnd ? c1 : try r.float32()
            switch method {
            case 0: state.subdivision = .constant(u: max(Int(c1), 3), v: max(Int(c2), 3))
            case 1 where c1 > 0: state.subdivision = .worldSpace(c1)
            default: state.subdivision = .default
            }
        case .triMesh, .triangle, .polygon, .box, .ellipsoid, .cone, .cylinder, .disk, .torus:
            let (mesh, own, parts) = try geometry(object, state: state)
            let hasColors = mesh.stream(.color) != nil
            let materials = parts.map { Material(material($0.over(state.attributes), state: state, hasVertexColors: hasColors)) }
            let geometry = Geometry(mesh: mesh, materials: materials)
            let node = Node(name: own.name ?? Self.name(in: object.children), geometry: geometry)
            node.transform = state.transform
            parent.addChild(node)
        default:
            break
        }
    }

    // MARK: Transforms

    /// A transform object's matrix. QuickDraw 3D's matrices act on row vectors, so they read transposed.
    static func transform(_ object: MetafileObject) throws(SceneFormatError) -> Matrix4x4 {
        var r = object.reader()
        switch object.type {
        case .matrixTransform:
            return Matrix4x4(quickDraw3D: try r.floats(16))
        case .scaleTransform:
            return Matrix4x4(scale: try r.vector3())
        case .translateTransform:
            return Matrix4x4(translation: try r.vector3())
        case .rotateTransform:
            let axis = try r.enumerated(["x": 0, "y": 1, "z": 2])
            let radians = try r.float32()
            return Matrix4x4(rotation: Quaternion(angle: radians, axis: Self.axis(axis)))
        case .rotateAboutPointTransform:
            let axis = try r.enumerated(["x": 0, "y": 1, "z": 2])
            let radians = try r.float32()
            let about = try r.vector3()
            return Matrix4x4(translation: about) * Matrix4x4(rotation: Quaternion(angle: radians, axis: Self.axis(axis))) * Matrix4x4(translation: -about)
        case .rotateAboutAxisTransform:
            let origin = try r.vector3()
            let orientation = try r.vector3()
            let radians = try r.float32()
            return Matrix4x4(translation: origin) * Matrix4x4(rotation: Quaternion(angle: radians, axis: orientation)) * Matrix4x4(translation: -origin)
        case .quaternionTransform:
            // TQ3Quaternion is w, x, y, z.
            let w = try r.float32(), x = try r.float32(), y = try r.float32(), z = try r.float32()
            return Matrix4x4(rotation: Quaternion(ix: x, iy: y, iz: z, r: w))
        default:
            return .identity
        }
    }

    private static func axis(_ value: UInt32) -> SIMD3<Float> {
        switch value {
        case 0: SIMD3(1, 0, 0)
        case 1: SIMD3(0, 1, 0)
        default: SIMD3(0, 0, 1)
        }
    }

    // MARK: Attributes

    /// An attribute set: its elements are its children.
    private func attributes(_ set: MetafileObject) throws(SceneFormatError) -> Attributes {
        var attributes = Attributes()
        for element in set.children {
            var r = element.reader()
            switch element.type {
            case .diffuseColor: attributes.diffuse = try r.vector3()
            case .specularColor: attributes.specular = try r.vector3()
            case .specularControl: attributes.specularControl = try r.float32()
            case .transparencyColor: attributes.transparency = try r.vector3()
            case .emissiveColor: attributes.emissive = try r.vector3()
            case .metallic: attributes.metallic = try r.float32()
            case .textureShader: attributes.texture = try texture(element)
            case .surfaceShaderAttribute:
                if let shader = element.children.first(where: { $0.type == .textureShader }) {
                    attributes.texture = try texture(shader)
                }
            case .nameElement: attributes.name = try Self.name(element)
            default: break
            }
        }
        return attributes
    }

    /// A texture shader's pixmap, as an image.
    private func texture(_ shader: MetafileObject) throws(SceneFormatError) -> ImageBuffer? {
        guard let pixmap = shader.children.first(where: { $0.type == .pixmapTexture }) else { return nil }
        var r = pixmap.reader()
        return try Pixmap.read(&r)
    }

    /// The name a name element gives: its own string, or the string object after it.
    private static func name(_ element: MetafileObject) throws(SceneFormatError) -> String? {
        var r = element.reader()
        if !r.isAtEnd { return try r.string() }
        guard let string = element.children.first(where: { $0.type == .cString }) else { return nil }
        var s = string.reader()
        return try s.string()
    }

    /// The name among an object's elements, if one names it.
    private static func name(in children: [MetafileObject]) -> String? {
        for child in children where child.type == .nameElement {
            if let name = try? name(child) { return name }
        }
        return nil
    }

    /// A material for the attributes: QuickDraw 3D's colours are linear, its transparency colour 1 for opaque, and a
    /// texture takes the diffuse colour's place.
    private func material(_ attributes: Attributes, state: State, hasVertexColors: Bool) -> MaterialDescriptor {
        var material = MaterialDescriptor(lightingModel: state.lightingModel ?? (attributes.specular != nil ? .phong : .lambert))
        if let texture = attributes.texture {
            material.diffuse = MaterialProperty(.texture(.image(texture)), sampler: TextureSampler(wrapS: .repeat, wrapT: .repeat, mipFilter: .linear))
        } else {
            let diffuse = hasVertexColors ? SIMD3<Float>(repeating: 1) : attributes.diffuse ?? SIMD3(repeating: 1)
            material.diffuse = .color(SIMD4(diffuse, 1))
        }
        if let specular = attributes.specular {
            material.specular = .color(SIMD4(specular, 1))
        }
        if let control = attributes.specularControl {
            // A specular exponent; the shininess scales to one by 128.
            material.shininess = max(control, 1) / 128
        }
        if let transparency = attributes.transparency {
            material.transparency = (transparency.x + transparency.y + transparency.z) / 3
        }
        if let emissive = attributes.emissive {
            material.emission = .color(SIMD4(emissive, 1))
        }
        if let metallic = attributes.metallic {
            material.metalness = .scalar(metallic)
        }
        material.name = attributes.name
        return material
    }

    // MARK: Geometry

    /// A geometry's mesh, its own attributes, and the attributes of each of its parts, in material order.
    private func geometry(_ object: MetafileObject, state: State) throws(SceneFormatError) -> (MeshBuffer, Attributes, [Attributes]) {
        var own = Attributes()
        for child in object.children where child.type == .attributeSet {
            own = try attributes(child).over(own)
        }
        own.name = own.name ?? Self.name(in: object.children)
        switch object.type {
        case .triMesh: return (try triMesh(object), own, [own])
        case .triangle: return (try polygon(object, count: 3), own, [own])
        case .polygon: return (try polygon(object, count: nil), own, [own])
        case .box: return (try box(object), own, [own])
        default: break
        }
        // A quadric: its face and caps may each have attributes of their own, over the geometry's.
        let surface = try quadric(object)
        func capAttributes(_ type: MetafileObjectType) throws(SceneFormatError) -> Attributes {
            var cap = Attributes()
            for set in object.children where set.type == type {
                for child in set.children where child.type == .attributeSet {
                    cap = try attributes(child).over(cap)
                }
            }
            return cap.over(own)
        }
        let parts: [Attributes] = [
            try capAttributes(.faceCapAttributeSet),
            try capAttributes(.topCapAttributeSet),
            try capAttributes(.bottomCapAttributeSet),
            try capAttributes(.interiorCapAttributeSet),
        ]
        let (u, v) = segments(for: surface, state: state)
        return (surface.makeMesh(uSegments: u, vSegments: v), own, parts)
    }

    /// An Ellipsoid, Cone, Cylinder or Torus: orientation, major radius, minor radius, origin (a Torus then its
    /// ratio); a Disk has no orientation. Then the parameter ranges, which may be left out, and a Caps child.
    private func quadric(_ object: MetafileObject) throws(SceneFormatError) -> QuadricSurface {
        var r = object.reader()
        let kind: QuadricSurface.Kind
        switch object.type {
        case .ellipsoid: kind = .ellipsoid
        case .cone: kind = .cone
        case .cylinder: kind = .cylinder
        case .disk: kind = .disk
        default: kind = .torus(ratio: 1)
        }
        var surface = QuadricSurface(kind)
        guard !r.isAtEnd else { return withCaps(surface, object) }
        if kind != .disk { surface.orientation = try r.vector3() }
        surface.majorRadius = try r.vector3()
        surface.minorRadius = try r.vector3()
        surface.origin = try r.vector3()
        if case .torus = kind { surface.kind = .torus(ratio: r.isAtEnd ? 1 : try r.float32()) }
        if !r.isAtEnd { surface.uMin = try r.float32() }
        if !r.isAtEnd { surface.uMax = try r.float32() }
        if !r.isAtEnd { surface.vMin = try r.float32() }
        if !r.isAtEnd { surface.vMax = try r.float32() }
        return withCaps(surface, object)
    }

    private func withCaps(_ surface: QuadricSurface, _ object: MetafileObject) -> QuadricSurface {
        var surface = surface
        for child in object.children where child.type == .caps {
            var r = child.reader()
            if let mask = try? r.enumerated(["none": 0, "top": 1, "bottom": 2, "interior": 4]) {
                surface.caps = QuadricSurface.Caps(rawValue: mask)
            }
        }
        return surface
    }

    /// The segments for a surface under the subdivision style. A world-space style divides the radii's and the
    /// axis's lengths, as transformed, by its length, as Quesa does.
    private func segments(for surface: QuadricSurface, state: State) -> (Int, Int) {
        switch state.subdivision {
        case .constant(let u, let v):
            return (u, v)
        case .worldSpace(let length):
            let m = state.transform
            let radius = max(m.transformDirection(surface.majorRadius).length, m.transformDirection(surface.minorRadius).length)
            let axis = max(radius, m.transformDirection(surface.orientation).length)
            let u = Int(2 * Float.pi * radius / length), v = Int(Float.pi * axis / length)
            return (min(max(u, 3), 256), min(max(v, 3), 256))
        }
    }

    /// A TriMesh: counts, triangles, edges, points and bounds, then its attribute arrays as children.
    private func triMesh(_ object: MetafileObject) throws(SceneFormatError) -> MeshBuffer {
        var r = object.reader()
        let triangleCount = Int(try r.uint32())
        let triangleAttributeTypes = Int(try r.uint32())
        let edgeCount = Int(try r.uint32())
        _ = try r.uint32() // Edge attribute types.
        let pointCount = Int(try r.uint32())
        let vertexAttributeTypes = Int(try r.uint32())
        guard triangleCount > 0, pointCount > 0, triangleCount < 1 << 26, pointCount < 1 << 26, edgeCount < 1 << 26 else {
            throw .malformed("A TriMesh of \(triangleCount) triangles and \(pointCount) points", offset: nil)
        }
        // Indices are as wide as the counts they index need.
        func index(below count: Int) throws(SceneFormatError) -> Int {
            if count >= 0x10000 { return Int(try r.uint32()) }
            if count >= 0x100 { return Int(try r.uint16()) }
            return Int(try r.uint8())
        }
        var triangles: [Int] = []
        triangles.reserveCapacity(triangleCount * 3)
        for _ in 0 ..< triangleCount * 3 {
            let i = try index(below: pointCount)
            guard i < pointCount else { throw .malformed("Point \(i) of \(pointCount)", offset: nil) }
            triangles.append(i)
        }
        for _ in 0..<edgeCount {
            _ = try index(below: pointCount); _ = try index(below: pointCount)
            _ = try index(below: triangleCount); _ = try index(below: triangleCount)
        }
        var points: [SIMD3<Float>] = []
        points.reserveCapacity(pointCount)
        for _ in 0..<pointCount { points.append(try r.vector3()) }

        // The attribute arrays: per triangle (0) or per vertex (2).
        var arrays = TriMeshAttributes()
        for child in object.children where child.type == .attributeArray {
            try arrays.read(child, triangleCount: triangleCount, edgeCount: edgeCount, pointCount: pointCount)
        }
        _ = (triangleAttributeTypes, vertexAttributeTypes)
        return arrays.mesh(points: points, triangles: triangles)
    }

    /// A Triangle (three points) or a Polygon (a count, then the points, convex), fanned into triangles.
    private func polygon(_ object: MetafileObject, count: Int?) throws(SceneFormatError) -> MeshBuffer {
        var r = object.reader()
        let n: Int
        if let count { n = count } else { n = Int(try r.uint32()) }
        guard n >= 3, n < 1 << 20 else { throw .malformed("A polygon of \(n) points", offset: nil) }
        var points: [SIMD3<Float>] = []
        for _ in 0..<n { points.append(try r.vector3()) }
        var triangles: [Int] = []
        for i in 1 ..< n - 1 { triangles += [0, i, i + 1] }
        return TriMeshAttributes().mesh(points: points, triangles: triangles)
    }

    /// A Box: an origin corner and three edges (orientation, major and minor axes); a unit cube by default.
    private func box(_ object: MetafileObject) throws(SceneFormatError) -> MeshBuffer {
        var r = object.reader()
        var orientation = SIMD3<Float>(0, 1, 0), major = SIMD3<Float>(0, 0, 1), minor = SIMD3<Float>(1, 0, 0), origin = SIMD3<Float>.zero
        if !r.isAtEnd {
            orientation = try r.vector3()
            major = try r.vector3()
            minor = try r.vector3()
            origin = try r.vector3()
        }
        let corners = (0..<8).map { i in
            origin + (i & 1 != 0 ? minor : .zero) + (i & 2 != 0 ? orientation : .zero) + (i & 4 != 0 ? major : .zero)
        }
        // Each face's corners, in order round it; wound outward below.
        let faces = [[0, 2, 6, 4], [1, 5, 7, 3], [0, 4, 5, 1], [2, 3, 7, 6], [0, 1, 3, 2], [4, 6, 7, 5]]
        let center = origin + (orientation + major + minor) / 2
        var points: [SIMD3<Float>] = [], triangles: [Int] = []
        for face in faces {
            var quad = face.map { corners[$0] }
            let normal = (quad[1] - quad[0]).cross(quad[2] - quad[0])
            if normal.dot(quad[0] - center) < 0 { quad.reverse() }
            let base = points.count
            points += quad
            triangles += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        return TriMeshAttributes().mesh(points: points, triangles: triangles)
    }
}

// MARK: - TriMesh attributes

/// A TriMesh's attribute arrays, and how they become vertex streams.
struct TriMeshAttributes {

    var vertexNormals: [SIMD3<Float>]?
    var vertexUVs: [SIMD2<Float>]?
    var vertexColors: [SIMD3<Float>?]?
    var vertexTransparency: [SIMD3<Float>?]?
    var faceNormals: [SIMD3<Float>?]?
    var faceColors: [SIMD3<Float>?]?

    /// An `AttributeArray`: type, a reserved word, which array (0 triangles, 1 edges, 2 vertices), the position in
    /// it, whether a use array follows, then the values.
    mutating func read(_ object: MetafileObject, triangleCount: Int, edgeCount: Int, pointCount: Int) throws(SceneFormatError) {
        var r = object.reader()
        let type = try r.int32()
        _ = try r.uint32()
        let which = try r.uint32()
        _ = try r.uint32()
        let hasUseArray = try r.uint32() != 0
        let count: Int
        switch which {
        case 0: count = triangleCount
        case 1: count = edgeCount
        case 2: count = pointCount
        default: throw .malformed("Attribute array for \(which)", offset: nil)
        }
        var used: [Bool]?
        if hasUseArray {
            used = []
            for _ in 0..<count { used?.append(try r.int8() != 0) }
        }
        func isUsed(_ i: Int) -> Bool { used?[i] ?? true }
        func vectors3() throws(SceneFormatError) -> [SIMD3<Float>?] {
            var values: [SIMD3<Float>?] = []
            for i in 0..<count { let v = try r.vector3(); values.append(isUsed(i) ? v : nil) }
            return values
        }
        switch (type, which) {
        case (1, 2), (2, 2): // Surface or shading UV.
            var uvs: [SIMD2<Float>] = []
            for _ in 0..<count { uvs.append(SIMD2(try r.float32(), try r.float32())) }
            if type == 1 || vertexUVs == nil { vertexUVs = uvs }
        case (3, 2): vertexNormals = try vectors3().map { $0 ?? SIMD3(0, 0, 1) }
        case (3, 0): faceNormals = try vectors3()
        case (5, 2): vertexColors = try vectors3()
        case (5, 0): faceColors = try vectors3()
        case (8, 2): vertexTransparency = try vectors3()
        default: break // Edges, and attributes nothing draws by yet.
        }
    }

    /// The mesh: indexed when every vertex's attributes are its own, else three vertices a triangle, so faces can
    /// have their own normals and colours. Without normals the faces are flat. Texture coordinates flip, since
    /// QuickDraw 3D's start at the bottom.
    func mesh(points: [SIMD3<Float>], triangles: [Int]) -> MeshBuffer {
        let hasColors = vertexColors != nil || faceColors != nil || vertexTransparency != nil
        let shared = vertexNormals != nil && faceColors == nil
        func color(vertex: Int, face: Int) -> SIMD4<Float> {
            let rgb = vertexColors?[vertex] ?? faceColors?[face] ?? SIMD3(repeating: 1)
            let alpha = vertexTransparency?[vertex].map { ($0.x + $0.y + $0.z) / 3 } ?? 1
            return SIMD4(rgb, alpha)
        }
        func uv(_ vertex: Int) -> SIMD2<Float> {
            let value = vertexUVs?[vertex] ?? .zero
            return SIMD2(value.x, 1 - value.y)
        }
        var streams: [VertexStream] = []
        let vertexCount: Int
        var indices: IndexBuffer?
        if shared {
            vertexCount = points.count
            streams.append(VertexStream(semantic: .position, vectors: points))
            streams.append(VertexStream(semantic: .normal, vectors: vertexNormals!.map(\.normalized)))
            if vertexUVs != nil { streams.append(VertexStream(semantic: .textureCoordinate(0), vectors: points.indices.map(uv))) }
            if hasColors {
                // Per vertex only here: face colours make the mesh unshared.
                streams.append(VertexStream(semantic: .color, vectors: points.indices.map { color(vertex: $0, face: 0) }))
            }
            indices = IndexBuffer(triangles)
        } else {
            vertexCount = triangles.count
            var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = [], colors: [SIMD4<Float>] = []
            for face in 0 ..< triangles.count / 3 {
                let corners = [triangles[face * 3], triangles[face * 3 + 1], triangles[face * 3 + 2]]
                let flat = faceNormals?[face]?.normalized
                    ?? (points[corners[1]] - points[corners[0]]).cross(points[corners[2]] - points[corners[0]]).normalized
                for vertex in corners {
                    positions.append(points[vertex])
                    normals.append(vertexNormals.map { $0[vertex].normalized } ?? flat)
                    uvs.append(uv(vertex))
                    colors.append(color(vertex: vertex, face: face))
                }
            }
            streams.append(VertexStream(semantic: .position, vectors: positions))
            streams.append(VertexStream(semantic: .normal, vectors: normals))
            if vertexUVs != nil { streams.append(VertexStream(semantic: .textureCoordinate(0), vectors: uvs)) }
            if hasColors { streams.append(VertexStream(semantic: .color, vectors: colors)) }
        }
        let count = indices?.count ?? vertexCount
        return MeshBuffer(vertexCount: vertexCount, streams: streams, indices: indices, submeshes: [Submesh(range: 0..<count, materialIndex: 0)])
    }
}
