// Ported from Quesa's 3DMF readers (E3FFR_3DMF*.cpp, E3Globals.h).
// Copyright (c) 1999-2021, Quesa Developers. All rights reserved.
// Licensed under the BSD 3-Clause License; see LICENSE-Quesa.

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
        ("Ellipsoid", .ellipsoid), ("Cone", .cone), ("Cylinder", .cylinder), ("Disk", .disk), ("Torus", .torus),
        ("Caps", .caps), ("TopCapAttributeSet", .topCapAttributeSet), ("BottomCapAttributeSet", .bottomCapAttributeSet),
        ("FaceCapAttributeSet", .faceCapAttributeSet), ("InteriorCapAttributeSet", .interiorCapAttributeSet),
        ("SubdivisionStyle", .subdivisionStyle), ("AttributeArray", .attributeArray),
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
    case binary([UInt8], Metafile3D.ByteOrder)
    case text([String])

    public static let empty = MetafileObjectData.text([])
}
