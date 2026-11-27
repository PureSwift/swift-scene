// Ported from Quesa's 3DMF readers (E3FFR_3DMF*.cpp, E3Globals.h).
// Copyright (c) 1999-2021, Quesa Developers. All rights reserved.
// Licensed under the BSD 3-Clause License; see LICENSE-Quesa.

import BinaryParsing

/// A 3D Metafile: QuickDraw 3D's scene file, binary or text, read into a tree of objects.
public struct Metafile3D: Sendable {

    public enum Encoding: Hashable, Sendable {
        case binary(ByteOrder)
        case text
    }

    public enum ByteOrder: Hashable, Sendable {
        case bigEndian
        case littleEndian
    }

    /// How the file is laid out: as a sequence of objects to draw in order, or a database of shared ones.
    public enum Mode: UInt32, Hashable, Sendable {
        case normal = 0
        case stream = 1
        case database = 2
    }

    public var encoding: Encoding

    public var majorVersion: UInt16

    public var minorVersion: UInt16

    public var mode: Mode

    /// The top-level objects, in order, with containers, groups and references resolved.
    public var objects: [MetafileObject]

    public init(encoding: Encoding, majorVersion: UInt16 = 1, minorVersion: UInt16 = 6, mode: Mode = .normal, objects: [MetafileObject]) {
        self.encoding = encoding
        self.majorVersion = majorVersion
        self.minorVersion = minorVersion
        self.mode = mode
        self.objects = objects
    }

    /// Reads a binary or text metafile, whichever the data is.
    public init(_ bytes: [UInt8]) throws(SceneFormatError) {
        if bytes.starts(with: Array("3DMetafile".utf8)) {
            var parser = TextMetafileParser(bytes)
            self = try parser.parse()
        } else {
            var parser = BinaryMetafileParser(bytes)
            self = try parser.parse()
        }
    }
}

/// An object's type: a four-character code, or a custom class's name.
public enum MetafileObjectType: Hashable, Sendable {
    case code(UInt32)
    case custom(String)

    public init(_ code: StaticString) {
        precondition(code.utf8CodeUnitCount == 4, "A type code has four characters")
        let bytes = UnsafeBufferPointer(start: code.utf8Start, count: 4)
        self = .code(bytes.reduce(0) { $0 << 8 | UInt32($1) })
    }

    /// The type a text metafile's class name stands for.
    init(className: String) {
        if let code = MetafileObjectType.codesByClassName[className.lowercased()] {
            self = .code(code)
        } else {
            self = .custom(className)
        }
    }

    public var code: UInt32? {
        if case .code(let code) = self { code } else { nil }
    }
}

extension MetafileObjectType: CustomStringConvertible {

    public var description: String {
        switch self {
        case .code(let code):
            let bytes = (0..<4).map { UInt8(truncatingIfNeeded: code >> (24 - 8 * $0)) }
            if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
                return "'" + String(decoding: bytes, as: UTF8.self) + "'"
            }
            return "0x" + String(code, radix: 16)
        case .custom(let name):
            return name
        }
    }
}

// MARK: - Known types

public extension MetafileObjectType {

    // Structure
    static let container = MetafileObjectType("cntr")
    static let beginGroup = MetafileObjectType("bgng")
    static let endGroup = MetafileObjectType("endg")
    static let reference = MetafileObjectType("rfrn")
    static let tableOfContents = MetafileObjectType("toc ")
    static let type = MetafileObjectType("type")
    static let viewHints = MetafileObjectType("vwhn")
    static let cString = MetafileObjectType("strc")
    /// QuickDraw 3D's name element: a string naming the object whose set it is in.
    static let nameElement = MetafileObjectType.custom("Apple Computer, Inc.:NameElement")

    // Groups
    static let group = MetafileObjectType("grup")
    static let displayGroup = MetafileObjectType("dspg")
    static let orderedDisplayGroup = MetafileObjectType("ordg")
    static let ioProxyDisplayGroup = MetafileObjectType("iopx")
    static let lightGroup = MetafileObjectType("lghg")
    static let infoGroup = MetafileObjectType("info")
    static let displayGroupState = MetafileObjectType("dgst")
    static let displayGroupBoundingBox = MetafileObjectType("dgbb")

    // Geometry
    static let triMesh = MetafileObjectType("tmsh")
    static let triangle = MetafileObjectType("trng")
    static let polygon = MetafileObjectType("plyg")
    static let box = MetafileObjectType("box ")
    static let generalPolygon = MetafileObjectType("gpgn")
    static let mesh = MetafileObjectType("mesh")
    static let triGrid = MetafileObjectType("trig")
    static let nurbCurve = MetafileObjectType("nrbc")
    static let nurbPatch = MetafileObjectType("nrbp")
    static let line = MetafileObjectType("line")
    static let polyLine = MetafileObjectType("plyl")
    static let ellipse = MetafileObjectType("elps")
    static let point = MetafileObjectType("pnt ")
    static let marker = MetafileObjectType("mrkr")
    static let pixmapMarker = MetafileObjectType("mrkp")
    static let generalPolygonHint = MetafileObjectType("gplh")
    static let meshCorners = MetafileObjectType("crnr")
    static let meshEdges = MetafileObjectType("edge")
    static let faceAttributeSetList = MetafileObjectType("fasl")
    static let vertexAttributeSetList = MetafileObjectType("vasl")
    static let geometryAttributeSetList = MetafileObjectType("gasl")
    static let ellipsoid = MetafileObjectType("elpd")
    static let cone = MetafileObjectType("cone")
    static let cylinder = MetafileObjectType("cyln")
    static let disk = MetafileObjectType("disk")
    static let torus = MetafileObjectType("tors")
    static let caps = MetafileObjectType("caps")
    static let topCapAttributeSet = MetafileObjectType("tcas")
    static let bottomCapAttributeSet = MetafileObjectType("bcas")
    static let faceCapAttributeSet = MetafileObjectType("fcas")
    static let interiorCapAttributeSet = MetafileObjectType("icas")

    // Styles
    static let subdivisionStyle = MetafileObjectType("sbdv")
    static let backfacingStyle = MetafileObjectType("bckf")
    static let orientationStyle = MetafileObjectType("ofdr")
    static let fillStyle = MetafileObjectType("fist")
    static let interpolationStyle = MetafileObjectType("intp")
    static let castShadowsStyle = MetafileObjectType("cash")

    // Lights
    static let ambientLight = MetafileObjectType("ambn")
    static let directionalLight = MetafileObjectType("drct")
    static let pointLight = MetafileObjectType("pntl")
    static let spotLight = MetafileObjectType("spot")
    static let lightData = MetafileObjectType("lida")

    // Cameras and view hints
    static let orthographicCamera = MetafileObjectType("orth")
    static let viewPlaneCamera = MetafileObjectType("vwpl")
    static let viewAngleCamera = MetafileObjectType("vana")
    static let cameraPlacement = MetafileObjectType("cmpl")
    static let cameraRange = MetafileObjectType("cmrg")
    static let cameraViewPort = MetafileObjectType("cmvp")
    static let imageClearColor = MetafileObjectType("imcc")
    static let imageDimensions = MetafileObjectType("imdm")

    /// A shader's UV boundaries, as a texture shader's child: wrap, clamp or mirror.
    static let shader = MetafileObjectType("shdr")
    static let attributeArray = MetafileObjectType("atar")

    // Transforms
    static let matrixTransform = MetafileObjectType("mtrx")
    static let scaleTransform = MetafileObjectType("scal")
    static let translateTransform = MetafileObjectType("trns")
    static let rotateTransform = MetafileObjectType("rott")
    static let rotateAboutPointTransform = MetafileObjectType("rtap")
    static let rotateAboutAxisTransform = MetafileObjectType("rtaa")
    static let quaternionTransform = MetafileObjectType("qtrn")
    static let resetTransform = MetafileObjectType("rset")

    // Attributes
    static let attributeSet = MetafileObjectType("attr")
    static let surfaceUV = MetafileObjectType("sruv")
    static let shadingUV = MetafileObjectType("shuv")
    static let normal = MetafileObjectType("nrml")
    static let ambientCoefficient = MetafileObjectType("camb")
    static let diffuseColor = MetafileObjectType("kdif")
    static let specularColor = MetafileObjectType("kspc")
    static let specularControl = MetafileObjectType("cspc")
    static let transparencyColor = MetafileObjectType("kxpr")
    static let emissiveColor = MetafileObjectType("kemi")
    static let metallic = MetafileObjectType("kmet")
    static let highlightState = MetafileObjectType("hlst")
    static let surfaceShaderAttribute = MetafileObjectType("ssat")

    // Shaders and textures
    static let textureShader = MetafileObjectType("txsu")
    static let phongIllumination = MetafileObjectType("phil")
    static let lambertIllumination = MetafileObjectType("lmil")
    static let nullIllumination = MetafileObjectType("nuil")
    static let nondirectionalIllumination = MetafileObjectType("ndil")
    static let shaderUVTransform = MetafileObjectType("sduv")
    static let pixmapTexture = MetafileObjectType("txpm")
    static let mipmapTexture = MetafileObjectType("txmm")

    /// Text metafiles' class names for the codes, as QuickDraw 3D's and Quesa's classes are named.
    internal static let classNames: [(String, MetafileObjectType)] = [
        ("Container", .container), ("BeginGroup", .beginGroup), ("EndGroup", .endGroup),
        ("Reference", .reference), ("TableOfContents", .tableOfContents), ("Type", .type), ("ViewHints", .viewHints), ("CString", .cString),
        ("Group", .group), ("DisplayGroup", .displayGroup), ("OrderedDisplayGroup", .orderedDisplayGroup),
        ("IOProxyDisplayGroup", .ioProxyDisplayGroup), ("LightGroup", .lightGroup), ("InfoGroup", .infoGroup),
        ("DisplayGroupState", .displayGroupState), ("DisplayGroupBBox", .displayGroupBoundingBox),
        ("TriMesh", .triMesh), ("Triangle", .triangle), ("Polygon", .polygon), ("Box", .box),
        ("GeneralPolygon", .generalPolygon), ("Mesh", .mesh), ("TriGrid", .triGrid), ("NURBCurve", .nurbCurve),
        ("NURBPatch", .nurbPatch), ("Line", .line), ("PolyLine", .polyLine), ("Ellipse", .ellipse), ("Point", .point),
        ("Marker", .marker), ("PixmapMarker", .pixmapMarker), ("GeneralPolygonHint", .generalPolygonHint),
        ("MeshCorners", .meshCorners), ("MeshEdges", .meshEdges), ("FaceAttributeSetList", .faceAttributeSetList),
        ("VertexAttributeSetList", .vertexAttributeSetList), ("GeometryAttributeSetList", .geometryAttributeSetList),
        ("Ellipsoid", .ellipsoid), ("Cone", .cone), ("Cylinder", .cylinder), ("Disk", .disk), ("Torus", .torus),
        ("Caps", .caps), ("TopCapAttributeSet", .topCapAttributeSet), ("BottomCapAttributeSet", .bottomCapAttributeSet),
        ("FaceCapAttributeSet", .faceCapAttributeSet), ("InteriorCapAttributeSet", .interiorCapAttributeSet),
        ("SubdivisionStyle", .subdivisionStyle), ("BackfacingStyle", .backfacingStyle),
        ("OrientationStyle", .orientationStyle), ("FillStyle", .fillStyle), ("InterpolationStyle", .interpolationStyle),
        ("CastShadowsStyle", .castShadowsStyle),
        ("AmbientLight", .ambientLight), ("DirectionalLight", .directionalLight), ("PointLight", .pointLight),
        ("SpotLight", .spotLight), ("LightData", .lightData),
        ("OrthographicCamera", .orthographicCamera), ("ViewPlaneCamera", .viewPlaneCamera),
        ("ViewAngleCamera", .viewAngleCamera), ("ViewAngleAspectCamera", .viewAngleCamera),
        ("CameraPlacement", .cameraPlacement), ("CameraRange", .cameraRange), ("CameraViewPort", .cameraViewPort),
        ("ImageClearColor", .imageClearColor), ("ImageDimensions", .imageDimensions), ("ViewHint", .viewHints),
        ("Shader", .shader), ("AttributeArray", .attributeArray),
        ("Matrix", .matrixTransform), ("Scale", .scaleTransform), ("Translate", .translateTransform),
        ("Rotate", .rotateTransform), ("RotateAboutPoint", .rotateAboutPointTransform),
        ("RotateAboutAxis", .rotateAboutAxisTransform), ("Quaternion", .quaternionTransform), ("Reset", .resetTransform),
        ("AttributeSet", .attributeSet), ("SurfaceUV", .surfaceUV), ("ShadingUV", .shadingUV), ("Normal", .normal),
        ("AmbientCoefficient", .ambientCoefficient), ("DiffuseColor", .diffuseColor), ("SpecularColor", .specularColor),
        ("SpecularControl", .specularControl), ("TransparencyColor", .transparencyColor),
        ("Quesa:EmissiveColor", .emissiveColor), ("Quesa:Metallic", .metallic), ("HighlightState", .highlightState),
        ("SurfaceShaderAttribute", .surfaceShaderAttribute),
        ("TextureShader", .textureShader), ("PhongIllumination", .phongIllumination),
        ("LambertIllumination", .lambertIllumination), ("NULLIllumination", .nullIllumination),
        ("NondirectionalIllumination", .nondirectionalIllumination), ("ShaderUVTransform", .shaderUVTransform),
        ("PixmapTexture", .pixmapTexture), ("MipmapTexture", .mipmapTexture),
    ]

    private static let codesByClassName: [String: UInt32] = Dictionary(
        classNames.compactMap { name, type in type.code.map { (name.lowercased(), $0) } },
        uniquingKeysWith: { first, _ in first }
    )
}

/// One object of a metafile: its type, its data, and the objects it contains.
///
/// A container's first object is the one it describes, and the rest are that object's children; this tree keeps
/// the first object with the rest as its `children`. A group's children are what follow its `BeginGroup` up to the
/// matching `EndGroup`, after any state objects in its container.
public struct MetafileObject: Sendable {

    public var type: MetafileObjectType

    /// The object's own data, in the file's encoding.
    public var data: MetafileObjectData

    public var children: [MetafileObject]

    /// A text metafile's label for the object.
    public var label: String?

    public init(type: MetafileObjectType, data: MetafileObjectData, children: [MetafileObject] = [], label: String? = nil) {
        self.type = type
        self.data = data
        self.children = children
        self.label = label
    }

    /// A reader for the object's data.
    func reader() -> MetafileDataReader {
        MetafileDataReader(data)
    }
}

/// An object's data, as the file encodes it.
public enum MetafileObjectData: Sendable {
    case binary(BinaryMetafileData)
    case text([String])

    public static let empty = MetafileObjectData.text([])
}

/// A binary object's data: a range of the file's bytes, which every object of the file shares rather than copies.
public struct BinaryMetafileData: Sendable {

    /// The whole file.
    let file: [UInt8]

    /// Where in it the object's data is.
    let range: ParserRange

    public let byteOrder: Metafile3D.ByteOrder

    init(file: [UInt8], range: ParserRange, byteOrder: Metafile3D.ByteOrder) {
        self.file = file
        self.range = range
        self.byteOrder = byteOrder
    }

    /// The object's bytes.
    public var bytes: ArraySlice<UInt8> { file[range.lowerBound ..< range.upperBound] }
}

// 3DMF structure follows Quesa's E3FFW_3DMFBin_Writer.cpp.
// Copyright (c) 1999-2021, Quesa Developers. All rights reserved.
// Licensed under the BSD 3-Clause License; see LICENSE-Quesa.

public extension Metafile3D {
    /// Writes the resolved tree in its current encoding, with references expanded inline.
    /// Output uses normal mode without a table of contents. Labels and original offsets are omitted.
    /// Changing `encoding` does not convert payloads; incompatible payloads throw `unsupported`.
    /// This serializes metafile objects, not renderer-oriented Scene geometry.
    func encoded() throws(SceneFormatError) -> [UInt8] {
        var writer = MetafileWriter(encoding: encoding)
        return try writer.write(self)
    }
}

private struct MetafileWriter {
    let encoding: Metafile3D.Encoding
    private var customTypes: [String: UInt32] = [:]
    private var usedCodes: Set<UInt32> = []
    private var declarations: [String] = []

    init(encoding: Metafile3D.Encoding) {
        self.encoding = encoding
    }

    mutating func write(_ file: Metafile3D) throws(SceneFormatError) -> [UInt8] {
        try collect(file.objects, depth: 0)
        switch encoding {
        case .text:
            var output = "3DMetafile ( \(file.majorVersion) \(file.minorVersion) Normal 0 )\n"
            for object in file.objects { output += try text(object, depth: 0) }
            return Array(output.utf8)
        case .binary:
            var output = word(0x33444D46) + word(16)
            output += word(UInt32(file.majorVersion) << 16 | UInt32(file.minorVersion))
            output += word(0) + word(0) + word(0)
            var candidate = UInt32.max
            for name in declarations {
                while usedCodes.contains(candidate), candidate > 0x80000000 { candidate -= 1 }
                guard !usedCodes.contains(candidate), candidate >= 0x80000000 else {
                    throw .unsupported("Too many custom 3DMF types")
                }
                customTypes[name] = candidate
                usedCodes.insert(candidate)
                var payload = word(candidate) + Array(name.utf8) + [0]
                while payload.count % 4 != 0 { payload.append(0) }
                output += try chunk(.type, payload)
            }
            for object in file.objects { output += try binary(object) }
            return output
        }
    }

    private mutating func collect(_ objects: [MetafileObject], depth: Int) throws(SceneFormatError) {
        guard depth < 128 else { throw .unsupported("Metafile tree is too deep to write") }
        for object in objects {
            guard ![.container, .beginGroup, .endGroup, .reference, .tableOfContents, .type].contains(object.type) else {
                throw .unsupported("Write resolved objects rather than structural records")
            }
            switch object.type {
            case .code(let code): usedCodes.insert(code)
            case .custom(let name):
                guard !name.utf8.contains(0) else { throw .malformed("A class name contains NUL", offset: nil) }
                if !declarations.contains(name) { declarations.append(name) }
            }
            try collect(object.children, depth: depth + 1)
        }
    }

    private func isGroup(_ type: MetafileObjectType) -> Bool {
        [.group, .displayGroup, .orderedDisplayGroup, .ioProxyDisplayGroup, .lightGroup, .infoGroup].contains(type)
    }

    private func isGroupState(_ object: MetafileObject) -> Bool {
        object.type == .displayGroupState || object.type == .displayGroupBoundingBox
    }

    private func word(_ value: UInt32) -> [UInt8] {
        let bytes = (0..<4).map { UInt8(truncatingIfNeeded: value >> (24 - $0 * 8)) }
        if encoding == .binary(.littleEndian) { return bytes.reversed() }
        return bytes
    }

    private func chunk(_ type: MetafileObjectType, _ payload: [UInt8]) throws(SceneFormatError) -> [UInt8] {
        let code: UInt32
        switch type {
        case .code(let value): code = value
        case .custom(let name):
            guard let value = customTypes[name] else { throw .unsupported("Unregistered class \(name)") }
            code = value
        }
        guard let count = UInt32(exactly: payload.count) else { throw .unsupported("3DMF object exceeds 4 GiB") }
        return word(code) + word(count) + payload
    }

    private func binary(_ object: MetafileObject) throws(SceneFormatError) -> [UInt8] {
        let payload: [UInt8]
        switch object.data {
        case .binary(let data):
            guard encoding == .binary(data.byteOrder) else {
                throw .unsupported("Binary payload byte order differs from the output encoding")
            }
            payload = Array(data.bytes)
        case .text(let values):
            guard values.isEmpty else { throw .unsupported("Text-to-binary payload conversion is not implemented") }
            payload = []
        }
        let own = try chunk(object.type, payload)
        if isGroup(object.type) {
            let stateCount = object.children.prefix(while: isGroupState).count
            var header = own
            for child in object.children.prefix(stateCount) { header += try binary(child) }
            var output = try chunk(.beginGroup, header)
            for child in object.children.dropFirst(stateCount) { output += try binary(child) }
            output += try chunk(.endGroup, [])
            return output
        }
        guard !object.children.isEmpty else { return own }
        var contents = own
        for child in object.children { contents += try binary(child) }
        return try chunk(.container, contents)
    }

    private func text(_ object: MetafileObject, depth: Int) throws(SceneFormatError) -> String {
        let name: String
        switch object.type {
        case .custom(let value): name = value
        case .code:
            guard let value = MetafileObjectType.classNames.first(where: { $0.1 == object.type })?.0 else {
                throw .unsupported("No text class name for \(object.type)")
            }
            name = value
        }
        let nameTokens = TextMetafileParser.tokenize(Array(name.utf8))
        guard !nameTokens.isEmpty, nameTokens.count <= 8,
              nameTokens.joined(separator: " ") == name,
              !nameTokens.contains(where: { ["(", ")", "|"].contains($0) || $0.contains("\"") }),
              !nameTokens[0].hasSuffix(":"),
              MetafileObjectType(className: name) == object.type else {
            throw .unsupported("Class name cannot be represented in text 3DMF")
        }
        let values: [String]
        switch object.data {
        case .text(let tokens):
            let joined = tokens.joined(separator: " ")
            guard TextMetafileParser.tokenize(Array(joined.utf8)) == tokens,
                  !tokens.contains(where: { $0 == "(" || $0 == ")" || $0.hasSuffix(":") }),
                  tokens.allSatisfy({ !$0.hasPrefix("\"") || ($0.count >= 2 && $0.hasSuffix("\"")) }) else {
                throw .malformed("Invalid text payload tokens", offset: nil)
            }
            values = tokens
        case .binary(let data):
            guard data.bytes.isEmpty else { throw .unsupported("Binary-to-text payload conversion is not implemented") }
            values = []
        }
        let indent = String(repeating: "    ", count: depth)
        func own(_ indentation: String) -> String {
            indentation + name + " ( " + values.joined(separator: " ") + " )\n"
        }
        if isGroup(object.type) {
            let stateCount = object.children.prefix(while: isGroupState).count
            var output = indent + "BeginGroup (\n" + own(indent + "    ")
            for child in object.children.prefix(stateCount) { output += try text(child, depth: depth + 1) }
            output += indent + ")\n"
            for child in object.children.dropFirst(stateCount) { output += try text(child, depth: depth + 1) }
            return output + indent + "EndGroup ( )\n"
        }
        guard !object.children.isEmpty else { return own(indent) }
        var output = indent + "Container (\n" + own(indent + "    ")
        for child in object.children { output += try text(child, depth: depth + 1) }
        return output + indent + ")\n"
    }
}
