import SceneCore

/// How a surface looks: a shared, mutable reference to a `MaterialDescriptor`, as SceneKit's materials are
/// shared among geometries.
public final class Material {

    public var descriptor: MaterialDescriptor

    public init(_ descriptor: MaterialDescriptor = .default) {
        self.descriptor = descriptor
    }

    public var name: String? {
        get { descriptor.name }
        set { descriptor.name = newValue }
    }

    public var lightingModel: LightingModel {
        get { descriptor.lightingModel }
        set { descriptor.lightingModel = newValue }
    }

    public var diffuse: MaterialProperty {
        get { descriptor.diffuse }
        set { descriptor.diffuse = newValue }
    }

    public var ambient: MaterialProperty {
        get { descriptor.ambient }
        set { descriptor.ambient = newValue }
    }

    public var specular: MaterialProperty {
        get { descriptor.specular }
        set { descriptor.specular = newValue }
    }

    public var emission: MaterialProperty {
        get { descriptor.emission }
        set { descriptor.emission = newValue }
    }

    public var normal: MaterialProperty {
        get { descriptor.normal }
        set { descriptor.normal = newValue }
    }

    public var metalness: MaterialProperty {
        get { descriptor.metalness }
        set { descriptor.metalness = newValue }
    }

    public var roughness: MaterialProperty {
        get { descriptor.roughness }
        set { descriptor.roughness = newValue }
    }

    public var shininess: Float {
        get { descriptor.shininess }
        set { descriptor.shininess = newValue }
    }

    public var transparency: Float {
        get { descriptor.transparency }
        set { descriptor.transparency = newValue }
    }

    public var isDoubleSided: Bool {
        get { descriptor.isDoubleSided }
        set { descriptor.isDoubleSided = newValue }
    }

    public var cullMode: CullMode {
        get { descriptor.cullMode }
        set { descriptor.cullMode = newValue }
    }

    public var blendMode: BlendMode {
        get { descriptor.blendMode }
        set { descriptor.blendMode = newValue }
    }
}
