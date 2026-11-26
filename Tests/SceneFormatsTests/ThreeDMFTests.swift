import Testing
import SceneCore
import SceneGraph
@testable import SceneFormats

// MARK: - Fixtures

/// A text metafile: a group moved by a translate, holding a named, red, textured quad that a reference shares.
private let textFixture = """
3DMetafile ( 1 6 Normal toc0> )
# A comment, to the end of the line.
BeginGroup (
\tDisplayGroup ( )
\tDisplayGroupState ( NoBoundingBox | NoBoundingSphere )
)
Translate ( 1 2 3 )
quad1:
Container (
\tTriMesh (
\t\t2 0 0 0 4 1
\t\t0 1 2  0 2 3
\t\t0 0 0  1 0 0  1 1 0  0 1 0
\t\t0 0 0  1 1 0  False
\t)
\tAttributeArray ( 1 0 2 0 0  0 0  1 0  1 1  0 1 )
\tContainer (
\t\tAttributeSet ( )
\t\tDiffuseColor ( 1 0 0 )
\t\tContainer (
\t\t\tTextureShader ( )
\t\t\tPixmapTexture ( 2 1 8 16 RGB16 BigEndian BigEndian 0x7C0003E0 0x00000000 )
\t\t)
\t)
\tContainer (
\t\tApple Computer, Inc.:NameElement ( )
\t\tCString ( "red \\"quad\\"" )
\t)
)
Reference ( 1 )
EndGroup ( )
toc0:
TableOfContents ( toc1> 2 -1 1 16 1  1 quad1> TriMesh )
"""

/// Writes binary metafiles for the tests, in either byte order.
private struct BinaryWriter {

    var order: Metafile3D.ByteOrder
    var bytes: [UInt8] = []

    mutating func code(_ s: String) {
        let ascii = Array(s.utf8)
        bytes += order == .bigEndian ? ascii : ascii.reversed()
    }

    mutating func uint32(_ v: UInt32) {
        let be = [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
        bytes += order == .bigEndian ? be : be.reversed()
    }

    mutating func uint64(_ v: UInt64) {
        if order == .bigEndian { uint32(UInt32(v >> 32)); uint32(UInt32(v & 0xFFFF_FFFF)) }
        else { uint32(UInt32(v & 0xFFFF_FFFF)); uint32(UInt32(v >> 32)) }
    }

    mutating func float(_ v: Float) { uint32(v.bitPattern) }

    mutating func string(_ s: String) {
        bytes += Array(s.utf8) + [0]
        while bytes.count % 4 != 0 { bytes.append(0) }
    }

    /// An object: its type, then its data's size, then the data `body` writes.
    mutating func object(_ type: String, _ body: (inout BinaryWriter) -> Void = { _ in }) {
        code(type)
        let sizeAt = bytes.count
        uint32(0)
        let start = bytes.count
        body(&self)
        let size = UInt32(bytes.count - start)
        var patch = BinaryWriter(order: order)
        patch.uint32(size)
        bytes.replaceSubrange(sizeAt ..< sizeAt + 4, with: patch.bytes)
    }

    mutating func patchUInt64(at offset: Int, _ value: UInt64) {
        var patch = BinaryWriter(order: order)
        patch.uint64(value)
        bytes.replaceSubrange(offset ..< offset + 8, with: patch.bytes)
    }
}

/// A binary metafile like the text one: a group, a translate, a triangle mesh in a container with a diffuse colour,
/// a custom-typed object, and a reference to the mesh through the table of contents.
private func binaryFixture(_ order: Metafile3D.ByteOrder) -> [UInt8] {
    var w = BinaryWriter(order: order)
    // Header: 3DMF, 16, version 1.6, normal, the table of contents' place.
    w.code("3DMF"); w.uint32(16); w.uint32(1 << 16 | 6); w.uint32(0)
    let tocField = w.bytes.count
    w.uint64(0)

    w.object("bgng") { $0.object("dspg") }
    w.object("trns") { $0.float(1); $0.float(2); $0.float(3) }
    w.object("type") { $0.uint32(UInt32(bitPattern: -1)); $0.string("Example:Custom") }
    // An object of the custom type: its negative code, a size, and its data.
    w.uint32(UInt32(bitPattern: -1)); w.uint32(4); w.uint32(42)
    let meshLocation = w.bytes.count
    w.object("cntr") { w in
        w.object("tmsh") { w in
            for v: UInt32 in [1, 0, 0, 0, 3, 0] { w.uint32(v) }
            w.bytes += [0, 1, 2] // Byte indices: under 256 points.
            for f: Float in [0, 0, 0, 1, 0, 0, 0, 1, 0] { w.float(f) }
            for f: Float in [0, 0, 0, 1, 1, 0] { w.float(f) }
            w.uint32(0)
        }
        w.object("cntr") { w in
            w.object("attr")
            w.object("kdif") { $0.float(0); $0.float(1); $0.float(0) }
        }
    }
    w.object("rfrn") { $0.uint32(1) }
    w.object("endg")

    let tocLocation = w.bytes.count
    w.object("toc ") { w in
        w.uint64(0); w.uint32(2); w.uint32(UInt32(bitPattern: -2)); w.uint32(1); w.uint32(16); w.uint32(1)
        w.uint32(1); w.uint64(UInt64(meshLocation)); w.code("tmsh")
    }
    w.patchUInt64(at: tocField, UInt64(tocLocation))
    return w.bytes
}

// MARK: - Tests

@Suite struct TextMetafileTests {

    @Test func parsesStructure() throws {
        let metafile = try Metafile3D(Array(textFixture.utf8))
        #expect(metafile.encoding == .text)
        #expect(metafile.majorVersion == 1 && metafile.minorVersion == 6)
        #expect(metafile.objects.count == 1)
        let group = try #require(metafile.objects.first)
        #expect(group.type == .displayGroup)
        // State, translate, the mesh, and the reference resolved to the mesh.
        #expect(group.children.map(\.type) == [.displayGroupState, .translateTransform, .triMesh, .triMesh])
        let mesh = group.children[2]
        #expect(mesh.label == "quad1")
        #expect(mesh.children.map(\.type) == [.attributeArray, .attributeSet, .nameElement])
        #expect(mesh.children[1].children.map(\.type) == [.diffuseColor, .textureShader])
    }

    @Test func decodesScene() throws {
        let scene = try ThreeDMFDecoder(isStrict: true).decodeScene(Array(textFixture.utf8))
        let group = try #require(scene.rootNode.children.first)
        #expect(group.children.count == 2)
        let quad = try #require(group.children.first)
        #expect(quad.name == "red \"quad\"")
        #expect(quad.position == SIMD3(1, 2, 3))
        let geometry = try #require(quad.geometry)
        // Vertex normals are absent, so the faces are flat: three vertices a triangle.
        #expect(geometry.mesh.vertexCount == 6)
        #expect(geometry.mesh.bounds == BoundingBox(min: .zero, max: SIMD3(1, 1, 0)))
        let normals = try #require(geometry.mesh.stream(.normal))
        #expect(Array(normals[0]) == [0, 0, 1])
        // QuickDraw 3D's v runs up; ours runs down.
        let uvs = try #require(geometry.mesh.stream(.textureCoordinate(0)))
        #expect(Array(uvs[2]) == [1, 0])
        // The texture replaces the diffuse colour: a red pixel, then a green one.
        guard case .texture(.image(let image)) = geometry.firstMaterial?.diffuse.contents else {
            Issue.record("Expected a texture")
            return
        }
        #expect(image.width == 2 && image.height == 1)
        #expect(Array(image.pixels[0..<8]) == [255, 0, 0, 255, 0, 255, 0, 255])
        // The reference shares the mesh, under the same transform.
        #expect(group.children[1].position == SIMD3(1, 2, 3))
    }

    @Test func toleratesUnclosedParentheses() throws {
        let text = "3DMetafile ( 1 6 Normal )\nContainer ( Triangle ( 0 0 0 1 0 0 0 1 0 )"
        let scene = try ThreeDMFDecoder(isStrict: true).decodeScene(Array(text.utf8))
        #expect(scene.rootNode.children.first?.geometry?.mesh.vertexCount == 3)
    }

    @Test func rejectsOtherFiles() {
        #expect(throws: SceneFormatError.self) { try Metafile3D(Array("hello".utf8)) }
    }
}

@Suite struct BinaryMetafileTests {

    @Test(arguments: [Metafile3D.ByteOrder.bigEndian, .littleEndian])
    func parsesStructure(_ order: Metafile3D.ByteOrder) throws {
        let metafile = try Metafile3D(binaryFixture(order))
        #expect(metafile.encoding == .binary(order))
        #expect(metafile.majorVersion == 1 && metafile.minorVersion == 6)
        let group = try #require(metafile.objects.first)
        #expect(group.type == .displayGroup)
        #expect(group.children.map(\.type) == [.translateTransform, .custom("Example:Custom"), .triMesh, .triMesh])
        #expect(group.children[2].children.first?.children.first?.type == .diffuseColor)
    }

    @Test(arguments: [Metafile3D.ByteOrder.bigEndian, .littleEndian])
    func decodesScene(_ order: Metafile3D.ByteOrder) throws {
        let scene = try ThreeDMFDecoder(isStrict: true).decodeScene(binaryFixture(order))
        let group = try #require(scene.rootNode.children.first)
        #expect(group.children.count == 2)
        let triangle = try #require(group.children.first)
        #expect(triangle.position == SIMD3(1, 2, 3))
        #expect(triangle.geometry?.mesh.positions == [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)])
        #expect(triangle.geometry?.firstMaterial?.diffuse.color == SIMD4(0, 1, 0, 1))
    }

    @Test func rejectsTruncatedFile() {
        let truncated = Array(binaryFixture(.bigEndian).prefix(40))
        #expect(throws: SceneFormatError.self) { try Metafile3D(truncated) }
    }
}

@Suite struct ThreeDMFTransformTests {

    private func object(_ type: MetafileObjectType, _ values: String) -> MetafileObject {
        MetafileObject(type: type, data: .text(values.split(separator: " ").map(String.init)))
    }

    @Test func rotateAboutPointKeepsThePoint() throws {
        let m = try ThreeDMFDecoder.transform(object(.rotateAboutPointTransform, "Z 1.5707964 1 0 0"))
        let p = m.transformPoint(SIMD3(1, 0, 0))
        #expect(abs(p.x - 1) < 1e-5 && abs(p.y) < 1e-5)
        let q = m.transformPoint(SIMD3(2, 0, 0))
        #expect(abs(q.x - 1) < 1e-5 && abs(q.y - 1) < 1e-5)
    }

    @Test func matrixReadsRowVectors() throws {
        let m = try ThreeDMFDecoder.transform(object(.matrixTransform, "1 0 0 0 0 1 0 0 0 0 1 0 5 6 7 1"))
        #expect(m.translation == SIMD3(5, 6, 7))
    }

    @Test func quaternionIsWFirst() throws {
        // A quarter turn about y: w = cos 45°, y = sin 45°.
        let m = try ThreeDMFDecoder.transform(object(.quaternionTransform, "0.70710677 0 0.70710677 0"))
        let p = m.transformPoint(SIMD3(1, 0, 0))
        #expect(abs(p.z + 1) < 1e-5)
    }
}

@Suite struct PixmapTests {

    @Test func byteOrdersAgree() {
        // One RGB16 pixel, pure blue: 0x001F.
        let big = Pixmap.convert([0x00, 0x1F], width: 1, height: 1, rowBytes: 2, type: .rgb16, littleEndian: false)
        let little = Pixmap.convert([0x1F, 0x00], width: 1, height: 1, rowBytes: 2, type: .rgb16, littleEndian: true)
        #expect(big.pixels == [0, 0, 255, 255])
        #expect(little.pixels == big.pixels)
    }

    @Test func formats() {
        #expect(Pixmap.convert([0x80, 0x10, 0x20, 0x30], width: 1, height: 1, rowBytes: 4, type: .argb32, littleEndian: false).pixels == [0x10, 0x20, 0x30, 0x80])
        #expect(Pixmap.convert([0x30, 0x20, 0x10], width: 1, height: 1, rowBytes: 3, type: .rgb24, littleEndian: true).pixels == [0x10, 0x20, 0x30, 255])
        #expect(Pixmap.convert([0xF8, 0x00], width: 1, height: 1, rowBytes: 2, type: .rgb16_565, littleEndian: false).pixels == [255, 0, 0, 255])
        #expect(Pixmap.convert([0x7C, 0x00], width: 1, height: 1, rowBytes: 2, type: .argb16, littleEndian: false).pixels == [255, 0, 0, 0])
    }
}

@Suite struct ThreeDMFQuadricTests {

    private let text = """
    3DMetafile ( 1 6 Normal )
    SubdivisionStyle ( Constant 24 12 )
    Container (
        Cone ( 0 4 0  0 0 1  3 0 0  0 -2 0  0.85 0.15 0 0.6 )
        Caps ( Bottom | Interior )
        Container ( BottomCapAttributeSet ( ) Container ( AttributeSet ( ) DiffuseColor ( 1 0 0 ) ) )
        Container ( InteriorCapAttributeSet ( ) Container ( AttributeSet ( ) DiffuseColor ( 1 1 0 ) ) )
        Container ( AttributeSet ( ) DiffuseColor ( 0 1 1 ) )
    )
    Ellipsoid ( )
    """

    @Test func decodesCapsAndTheirAttributes() throws {
        let scene = try ThreeDMFDecoder(isStrict: true).decodeScene(Array(text.utf8))
        let cone = try #require(scene.rootNode.children.first?.geometry)
        let mesh = cone.mesh
        #expect(mesh.submeshes.count == 4)
        #expect(!mesh.submeshes[QuadricSurface.Part.bottomCap.rawValue].range.isEmpty)
        #expect(mesh.submeshes[QuadricSurface.Part.topCap.rawValue].range.isEmpty)
        // The face takes the geometry's colour; each cap its own.
        #expect(cone.material(forSubmesh: 0).diffuse.color == SIMD4(0, 1, 1, 1))
        #expect(cone.material(forSubmesh: 2).diffuse.color == SIMD4(1, 0, 0, 1))
        #expect(cone.material(forSubmesh: 3).diffuse.color == SIMD4(1, 1, 0, 1))
        // 24 segments round, from the subdivision style.
        #expect(mesh.triangles(in: mesh.submeshes[2]).count == 24)
    }

    @Test func defaultEllipsoidIsQuickDraw3Ds() throws {
        let scene = try ThreeDMFDecoder(isStrict: true).decodeScene(Array(text.utf8))
        let ellipsoid = try #require(scene.rootNode.children.last?.geometry)
        // Orientation x, radii y and z: a unit sphere.
        let bounds = ellipsoid.mesh.bounds
        #expect(abs(bounds.max.x - 1) < 1e-5 && abs(bounds.min.x + 1) < 1e-5)
    }
}

@Suite struct ThreeDMFPolygonTests {

    private func decode(_ text: String) throws -> [Node] {
        try ThreeDMFDecoder(isStrict: true).decodeScene(Array(("3DMetafile ( 1 6 Normal )\n" + text).utf8)).rootNode.children
    }

    private func area(_ mesh: MeshBuffer) -> Float {
        let p = mesh.positions
        return mesh.triangles(in: mesh.submeshes[0]).reduce(0) { $0 + (p[$1.y] - p[$1.x]).cross(p[$1.z] - p[$1.x]).length / 2 }
    }

    @Test func generalPolygonWithHole() throws {
        let nodes = try decode("""
        GeneralPolygon ( 2  4  0 0 0  4 0 0  4 4 0  0 4 0  4  1 1 0  3 1 0  3 3 0  1 3 0 )
        """)
        let mesh = try #require(nodes.first?.geometry?.mesh)
        #expect(abs(area(mesh) - 12) < 1e-4)
    }

    @Test func vertexColorsFromAttributeSetList() throws {
        let nodes = try decode("""
        Container (
            Polygon ( 3  0 0 0  1 0 0  0 1 0 )
            Container (
                VertexAttributeSetList ( 3 Exclude 1 1 )
                Container ( AttributeSet ( ) DiffuseColor ( 1 0 0 ) )
                Container ( AttributeSet ( ) DiffuseColor ( 0 0 1 ) )
            )
            Container ( AttributeSet ( ) DiffuseColor ( 0 1 0 ) )
        )
        """)
        let mesh = try #require(nodes.first?.geometry?.mesh)
        let colors = try #require(mesh.stream(.color))
        // Vertex 1 is excluded, so takes the geometry's green; the others their own.
        #expect(Array(colors[0]) == [1, 0, 0, 1])
        #expect(Array(colors[1]) == [0, 1, 0, 1])
        #expect(Array(colors[2]) == [0, 0, 1, 1])
        #expect(nodes.first?.geometry?.firstMaterial?.diffuse.color == SIMD4(1, 1, 1, 1))
    }

    @Test func meshFacesContoursAndCorners() throws {
        // A square face with a square hole (a negative count), and a corner giving vertex 0 its own normal.
        let nodes = try decode("""
        Container (
            Mesh (
                8  0 0 0  4 0 0  4 4 0  0 4 0  1 1 0  3 1 0  3 3 0  1 3 0
                1 1
                4  0 1 2 3
                -4  4 5 6 7
            )
            Container (
                MeshCorners ( 1  0 1 0 )
                Container ( AttributeSet ( ) Normal ( 0 0.6 0.8 ) )
            )
        )
        """)
        let mesh = try #require(nodes.first?.geometry?.mesh)
        #expect(abs(area(mesh) - 12) < 1e-4)
        let normals = try #require(mesh.stream(.normal))
        #expect(Array(normals[0]) == [0, 0.6, 0.8])
        #expect(Array(normals[1]) == [0, 0, 1])
    }

    @Test func triGridAlternatesDiagonals() throws {
        let nodes = try decode("TriGrid ( 2 3  0 0 0  1 0 0  2 0 0  0 1 0  1 1 0  2 1 0 )")
        let mesh = try #require(nodes.first?.geometry?.mesh)
        #expect(mesh.triangles(in: mesh.submeshes[0]).count == 4)
        #expect(abs(area(mesh) - 2) < 1e-5)
    }

    @Test func curvesAreUnlitLines() throws {
        let nodes = try decode("""
        PolyLine ( 3  0 0 0, 1 0 0, 1 1 0 )
        Ellipse ( )
        NURBCurve ( 2 2  0 0 0 1  1 1 0 1  0 0 1 1 )
        """)
        #expect(nodes.count == 3)
        for node in nodes {
            #expect(node.geometry?.mesh.submeshes.first?.primitive == .lineStrip)
            #expect(node.geometry?.firstMaterial?.lightingModel == .unlit)
        }
        #expect(nodes[0].geometry?.mesh.positions.last == SIMD3(1, 1, 0))
    }

    @Test func degenerateGeometryIsSkipped() throws {
        #expect(try decode("Mesh ( 2  0 0 0  1 0 0  0 0 )").isEmpty)
        #expect(try decode("PolyLine ( 0 )").isEmpty)
    }
}

@Suite struct BinaryMetafileRobustnessTests {

    /// Every way a file can end early is an error, never a crash or a read past the end.
    @Test(arguments: [Metafile3D.ByteOrder.bigEndian, .littleEndian])
    func everyTruncationFailsCleanly(_ order: Metafile3D.ByteOrder) {
        let file = binaryFixture(order)
        for length in 0 ..< file.count {
            let prefix = Array(file.prefix(length))
            do {
                let metafile = try Metafile3D(prefix)
                _ = try? ThreeDMFDecoder().decodeScene(metafile)
            } catch {}
        }
    }

    /// Any one byte changed — sizes, offsets, counts — is read or rejected, never trusted past the data.
    @Test func everyByteFlipIsSafe() {
        let file = binaryFixture(.bigEndian)
        for offset in file.indices {
            for flip: UInt8 in [0xFF, 0x80, 0x01] {
                var damaged = file
                damaged[offset] ^= flip
                if let metafile = try? Metafile3D(damaged) {
                    _ = try? ThreeDMFDecoder().decodeScene(metafile)
                }
            }
        }
    }

    @Test func sizePastTheEndIsAnError() throws {
        var file = binaryFixture(.bigEndian)
        // The first object's size, after the 24-byte header and its type.
        file.replaceSubrange(28 ..< 32, with: [0x7F, 0xFF, 0xFF, 0xFF])
        #expect(throws: SceneFormatError.self) { try Metafile3D(file) }
    }

    @Test func objectDataIsSharedNotCopied() throws {
        let file = binaryFixture(.littleEndian)
        let metafile = try Metafile3D(file)
        guard case .binary(let data) = metafile.objects.first?.children.first?.data else {
            Issue.record("Expected binary data")
            return
        }
        // The translate's three floats, read in place from the file.
        #expect(data.bytes.count == 12)
        #expect(data.bytes.startIndex > 24)
    }
}

@Suite struct ThreeDMFViewTests {

    private func decode(_ text: String) throws -> Scene {
        try ThreeDMFDecoder(isStrict: true).decodeScene(Array(("3DMetafile ( 1 6 Normal )\n" + text).utf8))
    }

    private func isClose(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool { (a - b).length < 1e-4 }

    @Test func lights() throws {
        let scene = try decode("""
        Container ( AmbientLight ( ) LightData ( True 0.25 1 1 1 ) )
        Container ( DirectionalLight ( 0 -1 0 False ) LightData ( True 1 1 0.5 0 ) )
        Container ( PointLight ( 1 2 3 InverseSquare True ) LightData ( True 0.5 1 1 1 ) )
        Container ( SpotLight ( 0 5 0  0 -1 0  False None 0.2 0.4 0 ) LightData ( True 1 1 1 1 ) )
        Container ( PointLight ( 0 0 0 0 False ) LightData ( False 1 1 1 1 ) )
        """)
        let lights = scene.rootNode.children.compactMap(\.light)
        // The light that's off isn't made.
        #expect(lights.map(\.kind) == [.ambient, .directional, .omni, .spot])
        #expect(lights[0].intensity == 250)
        #expect(lights[1].color == SIMD3(1, 0.5, 0))
        #expect(lights[2].castsShadow)
        #expect(abs(lights[3].spotOuterAngle - degrees(radians: 0.8)) < 1e-4)
        // A directional light shines down its node's -z, which points along its direction.
        let sun = scene.rootNode.children[1]
        #expect(isClose(sun.worldTransform.transformDirection(SIMD3(0, 0, -1)), SIMD3(0, -1, 0)))
        #expect(scene.rootNode.children[2].position == SIMD3(1, 2, 3))
    }

    @Test func viewHintsCameraAndBackground() throws {
        let scene = try decode("""
        Container (
            ViewHints ( )
            Container (
                ViewAngleCamera ( 0.7853982 1.5 )
                CameraPlacement ( 0 0 5  0 0 0  0 1 0 )
                CameraRange ( 0.5 50 )
            )
            ImageClearColor ( 0.2 0.3 0.4 )
        )
        """)
        let node = try #require(scene.firstCameraNode)
        let camera = try #require(node.camera)
        #expect(abs(camera.fieldOfView - 45) < 1e-3)
        #expect(camera.projectionDirection == .vertical)
        #expect(camera.zNear == 0.5 && camera.zFar == 50)
        #expect(node.position == SIMD3(0, 0, 5))
        // Looking at the origin: down -z.
        #expect(isClose(node.worldTransform.transformDirection(SIMD3(0, 0, -1)), SIMD3(0, 0, -1)))
        #expect(scene.background.color == SIMD4(0.2, 0.3, 0.4, 1))
    }

    @Test func orthographicCamera() throws {
        let scene = try decode("OrthographicCamera ( -2 3 2 -3 )")
        let camera = try #require(scene.firstCameraNode?.camera)
        #expect(camera.usesOrthographicProjection)
        #expect(camera.orthographicScale == 3)
    }

    @Test func backfacingAndOrientation() throws {
        let triangle = "Triangle ( 0 0 0 1 0 0 0 1 0 )"
        let both = try decode(triangle)
        #expect(both.rootNode.children.first?.geometry?.firstMaterial?.isDoubleSided == true)
        let culled = try decode("BackfacingStyle ( Culled )\n" + triangle)
        let material = try #require(culled.rootNode.children.first?.geometry?.firstMaterial)
        #expect(!material.isDoubleSided && material.cullMode == .back)
        let clockwise = try decode("BackfacingStyle ( Culled )\nOrientationStyle ( Clockwise )\n" + triangle)
        #expect(clockwise.rootNode.children.first?.geometry?.firstMaterial?.cullMode == .front)
    }

    @Test func fillStyles() throws {
        let edges = try decode("FillStyle ( Edges )\nBox ( )")
        let mesh = try #require(edges.rootNode.children.first?.geometry?.mesh)
        #expect(mesh.submeshes.allSatisfy { $0.primitive == .lines })
        // A box's 12 triangles have 18 distinct edges: 12 sides and 6 diagonals.
        #expect(mesh.submeshes.reduce(0) { $0 + $1.range.count } == 36)
        #expect(edges.rootNode.children.first?.geometry?.firstMaterial?.lightingModel == .unlit)
        let points = try decode("FillStyle ( Points )\nTriangle ( 0 0 0 1 0 0 0 1 0 )")
        #expect(points.rootNode.children.first?.geometry?.mesh.submeshes.first?.primitive == .points)
    }

    @Test func textureBoundariesAndTransform() throws {
        let scene = try decode("""
        Container (
            TextureShader ( )
            PixmapTexture ( 1 1 4 32 RGB32 BigEndian BigEndian 0x00FF0000 )
            Shader ( Clamp Mirror )
            ShaderUVTransform ( 2 0 0  0 2 0  0 0 1 )
        )
        Triangle ( 0 0 0 1 0 0 0 1 0 )
        """)
        let diffuse = try #require(scene.rootNode.children.first?.geometry?.firstMaterial?.diffuse)
        #expect(diffuse.sampler.wrapS == .clamp && diffuse.sampler.wrapT == .mirror)
        // Doubling QuickDraw 3D's u and v doubles ours, about our v's flip: (0, 1) stays put.
        #expect(diffuse.contentsTransform.transformPoint(SIMD3(0.5, 0.25, 0)) == SIMD3(1, -0.5, 0))
        #expect(diffuse.contentsTransform.transformPoint(SIMD3(0, 1, 0)) == SIMD3(0, 1, 0))
    }

    @Test func hiddenDisplayGroup() throws {
        let scene = try decode("""
        BeginGroup ( DisplayGroup ( ) DisplayGroupState ( DoNotDraw ) )
        Triangle ( 0 0 0 1 0 0 0 1 0 )
        EndGroup ( )
        """)
        #expect(scene.rootNode.children.first?.isHidden == true)
    }
}

extension ThreeDMFViewTests {

    @Test func pointsAndMarkers() throws {
        let scene = try ThreeDMFDecoder(isStrict: true).decodeScene(Array("""
        3DMetafile ( 1 6 Normal )
        Point ( 1 2 3 )
        Marker ( 0 1 0  0 0  8 8 1 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 )
        """.utf8))
        #expect(scene.rootNode.children.count == 2)
        #expect(scene.rootNode.children.first?.geometry?.mesh.positions == [SIMD3(1, 2, 3)])
        #expect(scene.rootNode.children.last?.geometry?.mesh.submeshes.first?.primitive == .points)
    }
}
