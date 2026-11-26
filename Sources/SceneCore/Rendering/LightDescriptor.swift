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

    public var kind: Kind

    /// Linear RGB.
    public var color: SIMD3<Float>

    /// In lumens, as SceneKit's: 1000 is a light at its colour.
    public var intensity: Float

    /// In kelvin; 6500 is white.
    public var temperature: Float

    public var castsShadow: Bool

    /// Where an omni or spot light starts to fade, and where it is gone; an end of 0 never fades.
    public var attenuationStartDistance: Float

    public var attenuationEndDistance: Float

    public var attenuationFalloffExponent: Float

    /// A spot light's full-strength cone, and its edge, in degrees.
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
        spotOuterAngle: Float = 45
    ) {
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

    /// The colour scaled by the intensity, 1000 lumens as 1.
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

    public var zFar: Float

    public init(
        fieldOfView: Float = 60,
        projectionDirection: ProjectionDirection = .vertical,
        usesOrthographicProjection: Bool = false,
        orthographicScale: Float = 1,
        zNear: Float = 1,
        zFar: Float = 100
    ) {
        self.fieldOfView = fieldOfView
        self.projectionDirection = projectionDirection
        self.usesOrthographicProjection = usesOrthographicProjection
        self.orthographicScale = orthographicScale
        self.zNear = zNear
        self.zFar = zFar
    }

    /// The projection for a viewport of the aspect ratio, width over height.
    public func projectionMatrix(aspectRatio aspect: Float) -> Matrix4x4 {
        let aspect = aspect > 0 ? aspect : 1
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
