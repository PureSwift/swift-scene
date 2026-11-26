import SceneCore

/// A light a node carries: a shared, mutable reference to a `LightDescriptor`. It shines down the node's -z axis.
public final class Light {

    public var name: String?

    public var descriptor: LightDescriptor

    public init(_ descriptor: LightDescriptor = LightDescriptor()) {
        self.descriptor = descriptor
    }

    public convenience init(kind: LightDescriptor.Kind) {
        self.init(LightDescriptor(kind: kind))
    }

    public var kind: LightDescriptor.Kind {
        get { descriptor.kind }
        set { descriptor.kind = newValue }
    }

    public var color: SIMD3<Float> {
        get { descriptor.color }
        set { descriptor.color = newValue }
    }

    public var intensity: Float {
        get { descriptor.intensity }
        set { descriptor.intensity = newValue }
    }

    public var temperature: Float {
        get { descriptor.temperature }
        set { descriptor.temperature = newValue }
    }

    public var castsShadow: Bool {
        get { descriptor.castsShadow }
        set { descriptor.castsShadow = newValue }
    }

    public var attenuationStartDistance: Float {
        get { descriptor.attenuationStartDistance }
        set { descriptor.attenuationStartDistance = newValue }
    }

    public var attenuationEndDistance: Float {
        get { descriptor.attenuationEndDistance }
        set { descriptor.attenuationEndDistance = newValue }
    }

    public var attenuationFalloffExponent: Float {
        get { descriptor.attenuationFalloffExponent }
        set { descriptor.attenuationFalloffExponent = newValue }
    }

    public var spotInnerAngle: Float {
        get { descriptor.spotInnerAngle }
        set { descriptor.spotInnerAngle = newValue }
    }

    public var spotOuterAngle: Float {
        get { descriptor.spotOuterAngle }
        set { descriptor.spotOuterAngle = newValue }
    }
}
