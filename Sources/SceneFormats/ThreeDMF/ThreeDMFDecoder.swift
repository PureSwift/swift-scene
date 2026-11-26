// Ported from Quesa's 3DMF object readers (E3FFR_3DMF_Geometry.cpp, E3FFR_3DMF.cpp).
// Copyright (c) 1999-2021, Quesa Developers. All rights reserved.
// Licensed under the BSD 3-Clause License; see LICENSE-Quesa.

import SceneCore
import SceneGraph

/// Reads a 3D Metafile, binary or text, into a scene.
///
/// The objects are submitted in order as QuickDraw 3D would draw them: transforms, attribute sets and shaders
/// change the state for what follows in the same group; each group is a node, its state its own; each geometry
/// is a node placed by the transforms before it. Geometry is TriMesh, Triangle, Polygon, GeneralPolygon, Mesh,
/// TriGrid, Box, the quadrics (Ellipsoid, Cone, Cylinder, Disk, Torus), NURB patches and curves, Line, PolyLine, Ellipse,
/// and Point, with markers as points at their places. Lights, cameras and view hints become nodes and the scene's
/// background; backfacing, orientation, fill and subdivision styles shape what follows. Polyhedra, NURB trim curves,
/// fog and the rendering-only styles are skipped.
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
        try submit(metafile.objects, to: scene.rootNode, in: scene, state: &state)
        return scene
    }

    // MARK: State

    /// What QuickDraw 3D's view keeps while a group is drawn.
    struct State {
        var transform = Matrix4x4.identity
        var attributes = Attributes()
        var lightingModel: LightingModel?
        var subdivision = Subdivision.default
        /// Which sides of a surface draw; QuickDraw 3D draws both by default.
        var backfacing = Backfacing.both
        /// Whether front faces wind clockwise rather than counter-clockwise.
        var isClockwise = false
        var fill = Fill.filled
        var castsShadows = false
    }

    /// `TQ3BackfacingStyle`.
    enum Backfacing: UInt32 {
        case both = 0, culled = 1, flipped = 2, cullFront = 3

        static let names: [String: UInt32] = ["both": 0, "culled": 1, "flipped": 2, "cullfront": 3]
    }

    /// `TQ3FillStyle`.
    enum Fill: UInt32 {
        case filled = 0, edges = 1, points = 2

        static let names: [String: UInt32] = ["filled": 0, "edges": 1, "points": 2]
    }

    /// A texture shader's image and how it's laid on.
    struct TextureMap {
        var image: ImageBuffer
        var sampler = TextureSampler(wrapS: .repeat, wrapT: .repeat, mipFilter: .linear)
        var transform = Matrix4x4.identity
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
        var texture: TextureMap?
        var name: String?
        /// A vertex's, face's or corner's own normal.
        var normal: SIMD3<Float>?
        /// A vertex's surface (or shading) texture coordinates, QuickDraw 3D's way up.
        var uv: SIMD2<Float>?

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
                name: name,
                normal: normal ?? base.normal,
                uv: uv ?? base.uv
            )
        }
    }

    // MARK: Submitting

    private func submit(_ objects: [MetafileObject], to parent: Node, in scene: Scene, state: inout State) throws(SceneFormatError) {
        for object in objects {
            do {
                try submit(object, to: parent, in: scene, state: &state)
            } catch {
                if isStrict { throw error }
            }
        }
    }

    private func submit(_ object: MetafileObject, to parent: Node, in scene: Scene, state: inout State) throws(SceneFormatError) {
        switch object.type {
        case .group, .displayGroup, .orderedDisplayGroup, .ioProxyDisplayGroup, .lightGroup, .infoGroup:
            // A group draws with its own copy of the state, from where it is.
            let node = Node()
            node.transform = state.transform
            node.name = Self.name(in: object.children)
            // A display group's state may say not to draw it.
            if let groupState = object.children.first(where: { $0.type == .displayGroupState }) {
                var r = groupState.reader()
                let mask = try r.enumerated([
                    "none": 0, "isinline": 1, "inline": 1, "donotdraw": 2, "noboundingbox": 4,
                    "noboundingsphere": 8, "donotpick": 16, "donotbound": 32,
                ])
                node.isHidden = mask & 2 != 0
            }
            parent.addChild(node)
            var inner = state
            inner.transform = .identity
            try submit(object.children.filter { $0.type != .displayGroupState && $0.type != .displayGroupBoundingBox }, to: node, in: scene, state: &inner)
        case .viewHints:
            // The view a file was made for: its camera, lights and background, in the hints' children.
            var inner = state
            try submit(object.children, to: parent, in: scene, state: &inner)
        case .imageClearColor:
            var r = object.reader()
            let color = try r.vector3()
            scene.background = .color(SIMD4(color, 1))
        case .ambientLight, .directionalLight, .pointLight, .spotLight:
            if let node = try light(object, state: state) { parent.addChild(node) }
        case .orthographicCamera, .viewPlaneCamera, .viewAngleCamera:
            parent.addChild(try camera(object, state: state))
        case .backfacingStyle:
            var r = object.reader()
            state.backfacing = Backfacing(rawValue: try r.enumerated(Backfacing.names)) ?? .both
        case .orientationStyle:
            var r = object.reader()
            state.isClockwise = try r.enumerated(["counterclockwise": 0, "clockwise": 1]) == 1
        case .fillStyle:
            var r = object.reader()
            state.fill = Fill(rawValue: try r.enumerated(Fill.names)) ?? .filled
        case .castShadowsStyle:
            var r = object.reader()
            state.castsShadows = try r.boolean()
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
        case .triMesh, .triangle, .polygon, .box, .ellipsoid, .cone, .cylinder, .disk, .torus,
             .generalPolygon, .mesh, .triGrid, .nurbPatch, .nurbCurve, .line, .polyLine, .ellipse,
             .point, .marker, .pixmapMarker:
            var (mesh, own, parts) = try geometry(object, state: state)
            guard mesh.vertexCount > 0 else { break }
            // A fill style of edges or points draws the triangles' outlines or corners instead.
            if state.fill != .filled { mesh = Self.outline(mesh, points: state.fill == .points) }
            let hasColors = mesh.stream(.color) != nil
            let isLines = mesh.submeshes.first.map { $0.primitive != .triangles && $0.primitive != .triangleStrip } ?? false
            let materials = parts.map { part in
                var descriptor = material(part.over(state.attributes), state: state, hasVertexColors: hasColors)
                // Lines and points have no normals to light by.
                if isLines { descriptor.lightingModel = .unlit }
                return Material(descriptor)
            }
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
    func attributes(_ set: MetafileObject) throws(SceneFormatError) -> Attributes {
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
            case .normal: attributes.normal = try r.vector3()
            case .surfaceUV: attributes.uv = SIMD2(try r.float32(), try r.float32())
            case .shadingUV:
                let uv = SIMD2(try r.float32(), try r.float32())
                if attributes.uv == nil { attributes.uv = uv }
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

    /// A texture shader's pixmap, as an image, with its UV boundaries (a `Shader` child: wrap, clamp or mirror) and
    /// its UV transform (a `ShaderUVTransform` child).
    private func texture(_ shader: MetafileObject) throws(SceneFormatError) -> TextureMap? {
        guard let pixmap = shader.children.first(where: { $0.type == .pixmapTexture }) else { return nil }
        var r = pixmap.reader()
        var map = TextureMap(image: try Pixmap.read(&r))
        if let boundaries = shader.children.first(where: { $0.type == .shader }) {
            var b = boundaries.reader()
            let names: [String: UInt32] = ["wrap": 0, "clamp": 1, "mirror": 2]
            func mode(_ value: UInt32) -> TextureWrapMode {
                switch value {
                case 1: .clamp
                case 2: .mirror
                default: .repeat
                }
            }
            if !b.isAtEnd { map.sampler.wrapS = mode(try b.enumerated(names)) }
            if !b.isAtEnd { map.sampler.wrapT = mode(try b.enumerated(names)) }
        }
        if let uvTransform = shader.children.first(where: { $0.type == .shaderUVTransform }) {
            var t = uvTransform.reader()
            map.transform = Self.uvTransform(try t.floats(9))
        }
        return map
    }

    /// A shader UV transform: a 3 by 3 matrix acting on QuickDraw 3D's (u, v, 1) as a row vector, its v running up,
    /// as a contents transform on ours, whose v runs down.
    static func uvTransform(_ m: [Float]) -> Matrix4x4 {
        // The same transform on column vectors (u, v, 0, 1).
        var qd3d = Matrix4x4.identity
        qd3d[0, 0] = m[0]; qd3d[0, 1] = m[3]; qd3d[0, 3] = m[6]
        qd3d[1, 0] = m[1]; qd3d[1, 1] = m[4]; qd3d[1, 3] = m[7]
        // v up to v down, and back.
        var flip = Matrix4x4(scale: SIMD3(1, -1, 1))
        flip[1, 3] = 1
        return flip * qd3d * flip
    }

    /// The name a name element gives: its own string, or the string object after it.
    static func name(_ element: MetafileObject) throws(SceneFormatError) -> String? {
        var r = element.reader()
        if !r.isAtEnd { return try r.string() }
        guard let string = element.children.first(where: { $0.type == .cString }) else { return nil }
        var s = string.reader()
        return try s.string()
    }

    /// The name among an object's elements, if one names it.
    static func name(in children: [MetafileObject]) -> String? {
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
            material.diffuse = MaterialProperty(.texture(.image(texture.image)), sampler: texture.sampler, contentsTransform: texture.transform)
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
        // Which sides draw: both, or the front or back, the front being the side the orientation style says.
        switch state.backfacing {
        case .both, .flipped:
            material.isDoubleSided = true
        case .culled:
            material.cullMode = state.isClockwise ? .front : .back
        case .cullFront:
            material.cullMode = state.isClockwise ? .back : .front
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
        let color = own.over(state.attributes).diffuse ?? SIMD3(repeating: 1)
        switch object.type {
        case .triMesh: return (try triMesh(object), own, [own])
        case .triangle: return (try polygon(object, count: 3, defaultColor: color), own, [own])
        case .polygon: return (try polygon(object, count: nil, defaultColor: color), own, [own])
        case .generalPolygon: return (try generalPolygon(object, defaultColor: color), own, [own])
        case .mesh: return (try polygonMesh(object, defaultColor: color), own, [own])
        case .triGrid: return (try triGrid(object, defaultColor: color), own, [own])
        case .box: return (try box(object), own, [own])
        case .nurbPatch: return (try nurbPatch(object, state: state), own, [own])
        case .nurbCurve: return (try nurbCurve(object, state: state), own, [own])
        case .line: return (try polyLine(object, count: 2), own, [own])
        case .polyLine: return (try polyLine(object, count: nil), own, [own])
        case .ellipse: return (try ellipse(object, state: state), own, [own])
        case .point, .marker, .pixmapMarker:
            // A point, or a marker's place: its bitmap or pixmap, drawn facing the viewer, isn't.
            var r = object.reader()
            let location = try r.vector3()
            let mesh = MeshBuffer(
                vertexCount: 1,
                streams: [VertexStream(semantic: .position, vectors: [location])],
                submeshes: [Submesh(primitive: .points, range: 0..<1, materialIndex: 0)]
            )
            return (mesh, own, [own])
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

    /// A Triangle (three points) or a Polygon (a count, then the points), with a vertex attribute set list.
    private func polygon(_ object: MetafileObject, count: Int?, defaultColor: SIMD3<Float>) throws(SceneFormatError) -> MeshBuffer {
        var r = object.reader()
        let n: Int
        if let count { n = count } else { n = Int(try r.uint32()) }
        // Too few points to draw, as Quesa's deliberately broken samples have: nothing, not an error.
        guard n >= 3 else { return .empty }
        guard n < 1 << 20 else { throw .malformed("A polygon of \(n) points", offset: nil) }
        let vertexSets = try attributeSetList(.vertexAttributeSetList, in: object)
        var vertices: [PolygonMeshBuilder.Vertex] = []
        for i in 0..<n {
            vertices.append(.init(position: try r.vector3(), attributes: i < vertexSets.count ? vertexSets[i] ?? .init() : .init()))
        }
        var builder = PolygonMeshBuilder()
        builder.addFace([vertices])
        return builder.build(defaultColor: defaultColor)
    }

    /// A GeneralPolygon: a count of contours, each a count and its points; a vertex attribute set list runs over
    /// every contour's vertices in order. Contours combine by the even-odd rule.
    private func generalPolygon(_ object: MetafileObject, defaultColor: SIMD3<Float>) throws(SceneFormatError) -> MeshBuffer {
        var r = object.reader()
        let contourCount = Int(try r.uint32())
        guard contourCount >= 1 else { return .empty }
        guard contourCount < 1 << 16 else { throw .malformed("A polygon of \(contourCount) contours", offset: nil) }
        let vertexSets = try attributeSetList(.vertexAttributeSetList, in: object)
        var contours: [[PolygonMeshBuilder.Vertex]] = []
        var index = 0
        for _ in 0..<contourCount {
            let count = Int(try r.uint32())
            guard count < 1 << 20 else { throw .malformed("A contour of \(count) points", offset: nil) }
            var contour: [PolygonMeshBuilder.Vertex] = []
            for _ in 0..<count {
                contour.append(.init(position: try r.vector3(), attributes: index < vertexSets.count ? vertexSets[index] ?? .init() : .init()))
                index += 1
            }
            contours.append(contour)
        }
        var builder = PolygonMeshBuilder()
        builder.addFace(contours)
        return builder.build(defaultColor: defaultColor)
    }

    /// A Mesh: its vertices; a count of faces and of contours; then each face's vertex indices, a negative count
    /// marking a contour (a hole) of the face before it. Face and vertex attribute set lists, and corners — a
    /// vertex's attributes on particular faces — follow as children.
    private func polygonMesh(_ object: MetafileObject, defaultColor: SIMD3<Float>) throws(SceneFormatError) -> MeshBuffer {
        var r = object.reader()
        let vertexCount = Int(try r.uint32())
        guard vertexCount >= 3 else { return .empty }
        guard vertexCount < 1 << 24 else { throw .malformed("A mesh of \(vertexCount) vertices", offset: nil) }
        var points: [SIMD3<Float>] = []
        for _ in 0..<vertexCount { points.append(try r.vector3()) }
        let faceCount = Int(try r.uint32())
        let contourCount = Int(try r.uint32())
        guard faceCount + contourCount < 1 << 24 else { throw .malformed("A mesh of \(faceCount) faces", offset: nil) }
        var faces: [[[Int]]] = []
        for _ in 0 ..< faceCount + contourCount {
            let signed = Int(try r.int32())
            var loop: [Int] = []
            for _ in 0 ..< abs(signed) {
                let index = Int(try r.uint32())
                guard index < vertexCount else { throw .malformed("Vertex \(index) of \(vertexCount)", offset: nil) }
                loop.append(index)
            }
            if signed < 0, !faces.isEmpty {
                faces[faces.count - 1].append(loop)
            } else {
                faces.append([loop])
            }
        }
        let vertexSets = try attributeSetList(.vertexAttributeSetList, in: object)
        let faceSets = try attributeSetList(.faceAttributeSetList, in: object)
        // Corners: for each, a vertex, the faces it applies on, then (as children) its attribute set.
        var corners: [Int: [Int: Attributes]] = [:] // face → vertex → attributes
        for list in object.children where list.type == .meshCorners {
            var c = list.reader()
            let count = Int(try c.uint32())
            let sets = list.children.filter { $0.type == .attributeSet }
            for k in 0 ..< min(count, 1 << 20) {
                let vertex = Int(try c.uint32())
                let faceTotal = Int(try c.uint32())
                var cornerFaces: [Int] = []
                for _ in 0 ..< min(faceTotal, 1 << 20) { cornerFaces.append(Int(try c.uint32())) }
                guard k < sets.count else { continue }
                let set = try attributes(sets[k])
                for face in cornerFaces { corners[face, default: [:]][vertex] = set }
            }
        }
        var builder = PolygonMeshBuilder()
        for (f, loops) in faces.enumerated() {
            let contours = loops.map { loop in
                loop.map { index in
                    var attributes = index < vertexSets.count ? vertexSets[index] ?? .init() : .init()
                    if let corner = corners[f]?[index] { attributes = corner.over(attributes) }
                    return PolygonMeshBuilder.Vertex(position: points[index], attributes: attributes)
                }
            }
            builder.addFace(contours, attributes: f < faceSets.count ? faceSets[f] ?? .init() : .init())
        }
        return builder.build(defaultColor: defaultColor)
    }

    /// A TriGrid: rows and columns of points, two triangles a cell with the diagonal alternating by column, as Quesa
    /// cuts them; face attribute sets are per triangle.
    private func triGrid(_ object: MetafileObject, defaultColor: SIMD3<Float>) throws(SceneFormatError) -> MeshBuffer {
        var r = object.reader()
        let rows = Int(try r.uint32()), columns = Int(try r.uint32())
        guard rows >= 2, columns >= 2 else { return .empty }
        guard rows * columns < 1 << 24 else { throw .malformed("A \(rows)×\(columns) TriGrid", offset: nil) }
        var points: [SIMD3<Float>] = []
        for _ in 0 ..< rows * columns { points.append(try r.vector3()) }
        let vertexSets = try attributeSetList(.vertexAttributeSetList, in: object)
        let faceSets = try attributeSetList(.faceAttributeSetList, in: object)
        func vertex(_ i: Int) -> PolygonMeshBuilder.Vertex {
            .init(position: points[i], attributes: i < vertexSets.count ? vertexSets[i] ?? .init() : .init())
        }
        var builder = PolygonMeshBuilder()
        var facet = 0
        for row in 0 ..< rows - 1 {
            for col in 0 ..< columns - 1 {
                let v = row * columns + col
                let odd = col & 1 != 0
                for triangle in [[v, v + 1 + (odd ? columns : 0), v + columns], [v + (odd ? 0 : columns), v + 1, v + columns + 1]] {
                    builder.addFace([triangle.map(vertex)], attributes: facet < faceSets.count ? faceSets[facet] ?? .init() : .init())
                    facet += 1
                }
            }
        }
        return builder.build(defaultColor: defaultColor)
    }

    /// A NURBPatch: u and v orders, rows and columns, the control points (x, y, z, w), then the u and v knots.
    private func nurbPatch(_ object: MetafileObject, state: State) throws(SceneFormatError) -> MeshBuffer {
        var r = object.reader()
        let uOrder = Int(try r.uint32()), vOrder = Int(try r.uint32())
        let rows = Int(try r.uint32()), columns = Int(try r.uint32())
        guard rows * columns < 1 << 20, uOrder < 64, vOrder < 64 else { throw .malformed("A \(rows)×\(columns) NURB patch", offset: nil) }
        var points: [SIMD4<Float>] = []
        for _ in 0 ..< rows * columns { points.append(SIMD4(try r.float32(), try r.float32(), try r.float32(), try r.float32())) }
        let uKnots = try r.floats(columns + uOrder), vKnots = try r.floats(rows + vOrder)
        let patch = NURBSPatch(uOrder: uOrder, vOrder: vOrder, rows: rows, columns: columns, controlPoints: points, uKnots: uKnots, vKnots: vKnots)
        guard patch.isValid else { throw .malformed("An inconsistent NURB patch", offset: nil) }
        return patch.makeMesh(segmentsPerSpan: nurbsSegments(state))
    }

    /// A NURBCurve: its order, the number of points, the control points (x, y, z, w), then the knots.
    private func nurbCurve(_ object: MetafileObject, state: State) throws(SceneFormatError) -> MeshBuffer {
        var r = object.reader()
        let order = Int(try r.uint32()), count = Int(try r.uint32())
        guard count < 1 << 20, order < 64 else { throw .malformed("A NURB curve of \(count) points", offset: nil) }
        var points: [SIMD4<Float>] = []
        for _ in 0..<count { points.append(SIMD4(try r.float32(), try r.float32(), try r.float32(), try r.float32())) }
        let curve = NURBSCurve(order: order, controlPoints: points, knots: try r.floats(count + order))
        guard curve.isValid else { throw .malformed("An inconsistent NURB curve", offset: nil) }
        return curve.makeMesh(segmentsPerSpan: nurbsSegments(state))
    }

    /// Segments a knot span for curves and patches: a constant style's first count, else Quesa's look of 8.
    private func nurbsSegments(_ state: State) -> Int {
        if case .constant(let u, _) = state.subdivision, u != 16 { return min(max(u, 1), 64) }
        return 8
    }

    /// An Ellipse: major and minor radii and an origin, then the part of it drawn (u from 0 to 1, from the major
    /// radius toward the minor), as a line strip; by default a unit circle in the plane of y and z.
    private func ellipse(_ object: MetafileObject, state: State) throws(SceneFormatError) -> MeshBuffer {
        var r = object.reader()
        var major = SIMD3<Float>(0, 1, 0), minor = SIMD3<Float>(0, 0, 1), origin = SIMD3<Float>.zero
        var uMin: Float = 0, uMax: Float = 1
        if !r.isAtEnd {
            major = try r.vector3()
            minor = try r.vector3()
            origin = try r.vector3()
            if !r.isAtEnd { uMin = try r.float32() }
            if !r.isAtEnd { uMax = try r.float32() }
        }
        if uMax < uMin { uMax += 1 }
        let segments: Int
        if case .constant(let u, _) = state.subdivision { segments = u } else { segments = 16 }
        let count = max(Int(Float(segments) * (uMax - uMin)), 2)
        let points = (0...count).map { i -> SIMD3<Float> in
            let angle = 2 * Float.pi * (uMin + (uMax - uMin) * Float(i) / Float(count))
            return origin + major * Elementary.cos(angle) + minor * Elementary.sin(angle)
        }
        return MeshBuffer(
            vertexCount: points.count,
            streams: [VertexStream(semantic: .position, vectors: points)],
            submeshes: [Submesh(primitive: .lineStrip, range: 0 ..< points.count, materialIndex: 0)]
        )
    }

    /// A Line (two points) or a PolyLine (a count, then the points), as a line strip.
    private func polyLine(_ object: MetafileObject, count: Int?) throws(SceneFormatError) -> MeshBuffer {
        var r = object.reader()
        let n: Int
        if let count { n = count } else { n = Int(try r.uint32()) }
        guard n >= 2 else { return .empty }
        guard n < 1 << 20 else { throw .malformed("A line of \(n) points", offset: nil) }
        var points: [SIMD3<Float>] = []
        for _ in 0..<n { points.append(try r.vector3()) }
        return MeshBuffer(
            vertexCount: n,
            streams: [VertexStream(semantic: .position, vectors: points)],
            submeshes: [Submesh(primitive: .lineStrip, range: 0..<n, materialIndex: 0)]
        )
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
