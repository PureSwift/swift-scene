/// How a surface is lit.
public enum LightingModel: Hashable, Sendable {
    /// Metallic-roughness physically based shading.
    case physicallyBased
    /// Blinn-Phong: SceneKit's default.
    case blinn
    case phong
    /// Diffuse only.
    case lambert
    /// No lighting: the diffuse colour as it is.
    case unlit
}

/// An image in memory.
public struct ImageBuffer: Hashable, Sendable {

    public enum PixelFormat: Hashable, Sendable {
        case rgba8
        case bgra8
        /// QuickDraw 3D's `kQ3PixelTypeARGB32`.
        case argb8
        case rgb8
        /// Five bits a channel, as QuickDraw 3D's `kQ3PixelTypeRGB16`.
        case rgb555
        case r8
        case rgba32Float

        public var bytesPerPixel: Int {
            switch self {
            case .rgba8, .bgra8, .argb8: 4
            case .rgb8: 3
            case .rgb555: 2
            case .r8: 1
            case .rgba32Float: 16
            }
        }
    }

    public var width: Int

    public var height: Int

    public var format: PixelFormat

    public var bytesPerRow: Int

    /// Rows from the top.
    public var pixels: [UInt8]

    public init(width: Int, height: Int, format: PixelFormat, bytesPerRow: Int? = nil, pixels: [UInt8]) {
        let bytesPerRow = bytesPerRow ?? width * format.bytesPerPixel
        precondition(pixels.count >= bytesPerRow * height, "An image's pixels fill its rows")
        self.width = width
        self.height = height
        self.format = format
        self.bytesPerRow = bytesPerRow
        self.pixels = pixels
    }
}

/// Where a texture's image comes from.
public enum TextureSource: Hashable, Sendable {
    /// A name a renderer's asset lookup resolves.
    case named(String)
    /// A file path or URL string.
    case path(String)
    case image(ImageBuffer)
}

public enum TextureWrapMode: Hashable, Sendable {
    case clamp
    case `repeat`
    case clampToBorder
    case mirror
}

public enum TextureFilterMode: Hashable, Sendable {
    case none
    case nearest
    case linear
}

/// How a texture is sampled.
public struct TextureSampler: Hashable, Sendable {

    public var wrapS: TextureWrapMode

    public var wrapT: TextureWrapMode

    public var minificationFilter: TextureFilterMode

    public var magnificationFilter: TextureFilterMode

    public var mipFilter: TextureFilterMode

    public var maxAnisotropy: Float

    public init(
        wrapS: TextureWrapMode = .clamp,
        wrapT: TextureWrapMode = .clamp,
        minificationFilter: TextureFilterMode = .linear,
        magnificationFilter: TextureFilterMode = .linear,
        mipFilter: TextureFilterMode = .none,
        maxAnisotropy: Float = 1
    ) {
        self.wrapS = wrapS
        self.wrapT = wrapT
        self.minificationFilter = minificationFilter
        self.magnificationFilter = magnificationFilter
        self.mipFilter = mipFilter
        self.maxAnisotropy = maxAnisotropy
    }
}

/// What a material property holds.
public enum MaterialContents: Hashable, Sendable {
    case none
    /// Linear RGBA.
    case color(SIMD4<Float>)
    case scalar(Float)
    case texture(TextureSource)
}

/// One of a material's inputs: its contents and how a texture is laid on.
public struct MaterialProperty: Hashable, Sendable {

    public var contents: MaterialContents

    public var intensity: Float

    public var sampler: TextureSampler

    /// Which texture coordinate channel a texture is laid out by.
    public var mappingChannel: Int

    /// How a texture is laid over the texture coordinates.
    public var contentsTransform: Matrix4x4

    public init(
        _ contents: MaterialContents = .none,
        intensity: Float = 1,
        sampler: TextureSampler = TextureSampler(),
        mappingChannel: Int = 0,
        contentsTransform: Matrix4x4 = .identity
    ) {
        self.contents = contents
        self.intensity = intensity
        self.sampler = sampler
        self.mappingChannel = mappingChannel
        self.contentsTransform = contentsTransform
    }

    public static func color(_ rgba: SIMD4<Float>) -> MaterialProperty { MaterialProperty(.color(rgba)) }

    public static func scalar(_ value: Float) -> MaterialProperty { MaterialProperty(.scalar(value)) }

    public static func texture(_ source: TextureSource) -> MaterialProperty { MaterialProperty(.texture(source)) }

    /// The colour, when the contents are one; a scalar as grey.
    public var color: SIMD4<Float>? {
        switch contents {
        case .color(let color): color
        case .scalar(let value): SIMD4(value, value, value, 1)
        case .none, .texture: nil
        }
    }
}

public enum CullMode: Hashable, Sendable {
    case back
    case front
}

public enum BlendMode: Hashable, Sendable {
    /// Over what is behind, by alpha.
    case alpha
    case add
    case multiply
    /// No blending.
    case replace
}

/// A material, as a value every renderer reads the same way.
public struct MaterialDescriptor: Hashable, Sendable {

    public var name: String?

    public var lightingModel: LightingModel

    /// The diffuse colour, or a physically based material's base colour.
    public var diffuse: MaterialProperty

    public var ambient: MaterialProperty

    public var specular: MaterialProperty

    public var emission: MaterialProperty

    public var normal: MaterialProperty

    public var metalness: MaterialProperty

    public var roughness: MaterialProperty

    public var ambientOcclusion: MaterialProperty

    /// A texture's alpha, or a colour's, as how transparent the surface is.
    public var transparent: MaterialProperty

    /// How sharp a Blinn or Phong highlight is.
    public var shininess: Float

    /// 1 for opaque, 0 for clear.
    public var transparency: Float

    public var isDoubleSided: Bool

    public var cullMode: CullMode

    public var blendMode: BlendMode

    public var writesToDepthBuffer: Bool

    public var readsFromDepthBuffer: Bool

    public init(
        name: String? = nil,
        lightingModel: LightingModel = .blinn,
        diffuse: MaterialProperty = .color(SIMD4(1, 1, 1, 1)),
        ambient: MaterialProperty = .color(SIMD4(0, 0, 0, 1)),
        specular: MaterialProperty = .color(SIMD4(0, 0, 0, 1)),
        emission: MaterialProperty = .color(SIMD4(0, 0, 0, 1)),
        normal: MaterialProperty = MaterialProperty(),
        metalness: MaterialProperty = .scalar(0),
        roughness: MaterialProperty = .scalar(0.5),
        ambientOcclusion: MaterialProperty = MaterialProperty(),
        transparent: MaterialProperty = MaterialProperty(),
        shininess: Float = 1,
        transparency: Float = 1,
        isDoubleSided: Bool = false,
        cullMode: CullMode = .back,
        blendMode: BlendMode = .alpha,
        writesToDepthBuffer: Bool = true,
        readsFromDepthBuffer: Bool = true
    ) {
        self.name = name
        self.lightingModel = lightingModel
        self.diffuse = diffuse
        self.ambient = ambient
        self.specular = specular
        self.emission = emission
        self.normal = normal
        self.metalness = metalness
        self.roughness = roughness
        self.ambientOcclusion = ambientOcclusion
        self.transparent = transparent
        self.shininess = shininess
        self.transparency = transparency
        self.isDoubleSided = isDoubleSided
        self.cullMode = cullMode
        self.blendMode = blendMode
        self.writesToDepthBuffer = writesToDepthBuffer
        self.readsFromDepthBuffer = readsFromDepthBuffer
    }

    public static let `default` = MaterialDescriptor()

    /// A physically based material.
    public static func physicallyBased(
        baseColor: SIMD4<Float> = SIMD4(1, 1, 1, 1),
        metalness: Float = 0,
        roughness: Float = 0.5
    ) -> MaterialDescriptor {
        MaterialDescriptor(lightingModel: .physicallyBased, diffuse: .color(baseColor), metalness: .scalar(metalness), roughness: .scalar(roughness))
    }

    /// A Phong material: QuickDraw 3D's and most older formats'.
    public static func phong(diffuse: SIMD4<Float>, specular: SIMD4<Float> = SIMD4(0, 0, 0, 1), shininess: Float = 1) -> MaterialDescriptor {
        MaterialDescriptor(lightingModel: .phong, diffuse: .color(diffuse), specular: .color(specular), shininess: shininess)
    }

    public static func lambert(diffuse: SIMD4<Float>) -> MaterialDescriptor {
        MaterialDescriptor(lightingModel: .lambert, diffuse: .color(diffuse))
    }

    public static func unlit(color: SIMD4<Float>) -> MaterialDescriptor {
        MaterialDescriptor(lightingModel: .unlit, diffuse: .color(color))
    }

    /// Whether drawing it needs blending.
    public var isTranslucent: Bool {
        transparency < 1 || (diffuse.color.map { $0.w < 1 } ?? false) || transparent.contents != .none
    }
}
