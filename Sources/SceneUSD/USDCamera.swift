import SceneCore
import SceneFormats
import SceneGraph

/// USD apertures and focal lengths use tenths of a scene unit; clipping uses scene units.
/// Keep lens distances in local scene units because the imported root carries unit conversion.
enum USDCamera {
    static func attributes(_ camera: Camera, aspect fallback: Float?) throws(SceneFormatError) -> [String] {
        let c = camera.descriptor
        guard let aspect = c.aspectRatio ?? fallback else {
            throw .unsupported("USD camera export requires a fixed aspect ratio or --aspect-ratio")
        }
        guard aspect.isFinite, aspect > 0, c.zNear.isFinite, c.zFar.isFinite, c.zFar > c.zNear else {
            throw USDRead.invalid("Invalid USD camera aspect or clipping planes")
        }
        let height: Float
        let focal: Float = 0.5
        if c.usesOrthographicProjection {
            guard c.zNear >= 0, c.orthographicScale.isFinite, c.orthographicScale > 0 else {
                throw USDRead.invalid("Invalid USD orthographic camera")
            }
            height = c.orthographicScale * 20
        } else {
            guard c.zNear > 0, c.fieldOfView.isFinite, c.fieldOfView > 0, c.fieldOfView < 180 else {
                throw USDRead.invalid("Invalid USD perspective camera")
            }
            let aperture = 2 * focal * Elementary.tan(c.fieldOfView * .pi / 360)
            height = c.projectionDirection == .horizontal ? aperture / aspect : aperture
        }
        let width = height * aspect
        guard height.isFinite, height > 0, width.isFinite, width > 0 else {
            throw USDRead.invalid("USD camera aperture overflow")
        }
        return [
            "token projection = \"\(c.usesOrthographicProjection ? "orthographic" : "perspective")\"",
            "float horizontalAperture = \(width)",
            "float verticalAperture = \(height)",
            "float focalLength = \(focal)",
            "float2 clippingRange = (\(c.zNear), \(c.zFar))"
        ]
    }

    static func decode(_ prim: USDPrim) throws(SceneFormatError) -> Camera {
        let allowed: Set<String> = ["projection", "horizontalAperture", "verticalAperture", "focalLength",
            "horizontalApertureOffset", "verticalApertureOffset", "clippingRange", "clippingPlanes",
            "fStop", "focusDistance", "shutter:open", "shutter:close", "stereoRole", "visibility", "purpose"]
        for property in prim.properties {
            guard allowed.contains(property.name) || property.name.hasPrefix("xformOp") ||
                    property.name == "material:binding" else {
                throw .unsupported("USD camera property \(property.name)")
            }
        }
        func scalar(_ name: String, _ fallback: Float, type: String = "float") throws(SceneFormatError) -> Float {
            try USDRead.scalar(USDRead.attribute(prim, name, types: [type]) ?? .number(String(fallback)))
        }
        for name in ["horizontalApertureOffset", "verticalApertureOffset", "fStop"] {
            guard try scalar(name, 0) == 0 else { throw .unsupported("USD camera \(name)") }
        }
        for name in ["shutter:open", "shutter:close"] {
            guard try scalar(name, 0, type: "double") == 0 else { throw .unsupported("USD camera motion blur") }
        }
        if let planes = try USDRead.attribute(prim, "clippingPlanes", types: ["float4[]"]),
           try !USDRead.array(planes).isEmpty { throw .unsupported("USD camera clipping planes") }
        if let role = try USDRead.attribute(prim, "stereoRole", types: ["token"]),
           try USDRead.string(role) != "mono" { throw .unsupported("USD stereo camera") }
        _ = try scalar("focusDistance", 0) // Inactive with fStop zero.
        let projection = try USDRead.string(USDRead.attribute(prim, "projection", types: ["token"]) ?? .string("perspective"))
        guard ["perspective", "orthographic"].contains(projection) else { throw USDRead.invalid("Invalid USD camera projection") }
        let width = try scalar("horizontalAperture", 20.955), height = try scalar("verticalAperture", 15.2908)
        let focal = try scalar("focalLength", 50)
        let clipping = try USDRead.tuple(USDRead.attribute(prim, "clippingRange", types: ["float2"]) ??
            .tuple([.number("1"), .number("1000000")]), count: 2)
        guard width > 0, height > 0, focal > 0, (width / height).isFinite, width / height > 0,
              clipping[0] >= 0, clipping[1] > clipping[0] else { throw USDRead.invalid("Invalid USD camera lens") }
        var c = CameraDescriptor()
        c.aspectRatio = width / height
        c.zNear = clipping[0]
        c.zFar = clipping[1]
        c.usesOrthographicProjection = projection == "orthographic"
        if c.usesOrthographicProjection {
            c.orthographicScale = height / 20
            guard c.orthographicScale > 0 else { throw USDRead.invalid("USD camera aperture underflow") }
        } else {
            c.fieldOfView = 2 * Elementary.atan(height / (2 * focal)) * 180 / .pi
            guard c.zNear > 0, c.fieldOfView > 0, c.fieldOfView < 180 else { throw USDRead.invalid("Invalid USD camera field of view") }
        }
        let camera = Camera(c)
        camera.name = try USDRead.string(prim.metadata["displayName"] ?? .string(prim.name))
        return camera
    }
}
