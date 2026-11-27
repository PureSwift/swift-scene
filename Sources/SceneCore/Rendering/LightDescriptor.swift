/// A light, as a value every renderer reads the same way. A light shines down its entity's -z axis.
public struct LightDescriptor: Hashable, Sendable {

    public enum Kind: Hashable, Sendable {
        /// From everywhere at once.
        case ambient
        /// From far away, all one way.
        case directional
        /// From a point, every way.
        case omni
        /// From a point, in a cone.
        case spot
    }

    public enum FalloffModel: Hashable, Sendable {
        /// The existing start/end/exponent curve and smooth spot cone.
        case legacy
        /// Inverse-square distance falloff, range cutoff and squared spot cone for glTF lights.
        case inverseSquare
    }

    public var falloffModel: FalloffModel

    public var kind: Kind

    /// Linear RGB.
    public var color: SIMD3<Float>

    /// Legacy SceneKit-style strength: 1000 is a light at its colour.
    /// For inverse-square lights, stores 1000 times the candela (point/spot) or lux (directional).
    public var intensity: Float

    /// In kelvin; 6500 is white.
    public var temperature: Float

    public var castsShadow: Bool

    /// Legacy fade start/end; an end of 0 disables the legacy distance fade.
    /// Inverse-square lights use only the end as a cutoff range; 0 means no cutoff.
    public var attenuationStartDistance: Float

    public var attenuationEndDistance: Float

    public var attenuationFalloffExponent: Float

    /// Full cone angles in degrees: twice glTF's inner and outer half angles.
    public var spotInnerAngle: Float

    public var spotOuterAngle: Float

    public init(
        kind: Kind = .omni,
        color: SIMD3<Float> = SIMD3(repeating: 1),
        intensity: Float = 1000,
        temperature: Float = 6500,
        castsShadow: Bool = false,
        attenuationStartDistance: Float = 0,
        attenuationEndDistance: Float = 0,
        attenuationFalloffExponent: Float = 2,
        spotInnerAngle: Float = 0,
        spotOuterAngle: Float = 45,
        falloffModel: FalloffModel = .legacy
    ) {
        self.falloffModel = falloffModel
        self.kind = kind
        self.color = color
        self.intensity = intensity
        self.temperature = temperature
        self.castsShadow = castsShadow
        self.attenuationStartDistance = attenuationStartDistance
        self.attenuationEndDistance = attenuationEndDistance
        self.attenuationFalloffExponent = attenuationFalloffExponent
        self.spotInnerAngle = spotInnerAngle
        self.spotOuterAngle = spotOuterAngle
    }

    /// The colour scaled by normalized strength (candela/lux for inverse-square lights).
    public var radiance: SIMD3<Float> { color * (intensity / 1000) }
}

/// A camera's lens, as a value every renderer reads the same way. A camera looks down its entity's -z axis.
public struct CameraDescriptor: Hashable, Sendable {

    public enum ProjectionDirection: Hashable, Sendable {
        /// The field of view is the height's.
        case vertical
        /// The field of view is the width's.
        case horizontal
    }

    /// In degrees.
    public var fieldOfView: Float

    public var projectionDirection: ProjectionDirection

    public var usesOrthographicProjection: Bool

    /// Half the height an orthographic camera sees.
    public var orthographicScale: Float

    public var zNear: Float

    /// Positive infinity represents an infinite perspective far plane.
    public var zFar: Float

    /// A fixed asset camera aspect ratio; nil follows the render target.
    public var aspectRatio: Float?

    public init(
        fieldOfView: Float = 60,
        projectionDirection: ProjectionDirection = .vertical,
        usesOrthographicProjection: Bool = false,
        orthographicScale: Float = 1,
        zNear: Float = 1,
        zFar: Float = 100,
        aspectRatio: Float? = nil
    ) {
        self.fieldOfView = fieldOfView
        self.projectionDirection = projectionDirection
        self.usesOrthographicProjection = usesOrthographicProjection
        self.orthographicScale = orthographicScale
        self.zNear = zNear
        self.zFar = zFar
        self.aspectRatio = aspectRatio
    }

    /// The projection for a viewport of the aspect ratio, width over height.
    public func projectionMatrix(aspectRatio aspect: Float) -> Matrix4x4 {
        let requested = aspectRatio ?? aspect
        let aspect = requested > 0 ? requested : 1
        if usesOrthographicProjection {
            let top = orthographicScale, right = orthographicScale * aspect
            return .orthographic(left: -right, right: right, bottom: -top, top: top, near: zNear, far: zFar)
        }
        var fovy = radians(degrees: fieldOfView)
        if projectionDirection == .horizontal {
            fovy = 2 * Elementary.atan(Elementary.tan(fovy / 2) / aspect)
        }
        return .perspective(verticalFieldOfView: fovy, aspectRatio: aspect, near: zNear, far: zFar)
    }
}
