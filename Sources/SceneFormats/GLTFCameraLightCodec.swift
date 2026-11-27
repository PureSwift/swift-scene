import Foundation
import SceneCore
import SceneGraph

/// Shared glTF camera and punctual-light validation for the reader and writer.
enum GLTFCameraLightCodec {
    static func decodeCamera(_ source: GLTFDocument.Camera) throws(SceneFormatError) -> Camera {
        var descriptor = CameraDescriptor()
        if source.type == "perspective", let p = source.perspective, source.orthographic == nil {
            guard p.yfov.isFinite, p.yfov > 0, p.yfov < .pi, p.znear.isFinite, p.znear > 0,
                  p.zfar.map({ $0.isFinite && $0 > p.znear }) ?? true,
                  p.aspectRatio.map({ $0.isFinite && $0 > 0 }) ?? true else {
                throw .malformed("Invalid perspective camera", offset: nil)
            }
            descriptor.fieldOfView = p.yfov * 180 / .pi
            descriptor.aspectRatio = p.aspectRatio
            descriptor.zNear = p.znear
            descriptor.zFar = p.zfar ?? .infinity
        } else if source.type == "orthographic", let o = source.orthographic, source.perspective == nil {
            guard [o.xmag, o.ymag, o.znear, o.zfar].allSatisfy(\.isFinite),
                  o.xmag > 0, o.ymag > 0, o.znear >= 0, o.zfar > o.znear,
                  (o.xmag / o.ymag).isFinite, o.xmag / o.ymag > 0 else {
                throw .malformed("Invalid orthographic camera", offset: nil)
            }
            descriptor.usesOrthographicProjection = true
            descriptor.orthographicScale = o.ymag
            descriptor.aspectRatio = o.xmag / o.ymag
            descriptor.zNear = o.znear
            descriptor.zFar = o.zfar
        } else { throw .malformed("Invalid glTF camera", offset: nil) }
        let camera = Camera(descriptor)
        camera.name = source.name
        return camera
    }

    static func encodeCamera(_ camera: Camera, fallbackAspect: Float?) throws(SceneFormatError) -> [String: Any] {
        let c = camera.descriptor
        let aspect = c.aspectRatio ?? fallbackAspect
        guard aspect.map({ $0.isFinite && $0 > 0 }) ?? true,
              c.zNear.isFinite, c.zFar > c.zNear else {
            throw .malformed("Invalid camera aspect ratio or clipping planes", offset: nil)
        }
        var result: [String: Any] = [:]
        if let name = camera.name { result["name"] = name }
        if c.usesOrthographicProjection {
            guard let aspect else { throw .unsupported("Orthographic GLB export requires a camera aspect ratio or --aspect-ratio") }
            let width = c.orthographicScale * aspect
            guard c.zNear >= 0, c.zFar.isFinite, c.orthographicScale.isFinite,
                  c.orthographicScale > 0, width.isFinite, width > 0 else {
                throw .malformed("Invalid orthographic camera", offset: nil)
            }
            result["type"] = "orthographic"
            result["orthographic"] = ["xmag": width, "ymag": c.orthographicScale, "znear": c.zNear, "zfar": c.zFar]
        } else {
            guard c.fieldOfView.isFinite, c.fieldOfView > 0, c.fieldOfView < 180, c.zNear > 0 else {
                throw .malformed("Invalid perspective camera", offset: nil)
            }
            var yfov = c.fieldOfView * .pi / 180
            if c.projectionDirection == .horizontal {
                guard let aspect else { throw .unsupported("Horizontal-FOV GLB export requires a camera aspect ratio or --aspect-ratio") }
                yfov = 2 * Elementary.atan(Elementary.tan(yfov / 2) / aspect)
            }
            guard yfov.isFinite, yfov > 0, yfov < .pi else { throw .malformed("Invalid vertical field of view", offset: nil) }
            var perspective: [String: Any] = ["yfov": yfov, "znear": c.zNear]
            if c.zFar.isFinite { perspective["zfar"] = c.zFar }
            if let aspect { perspective["aspectRatio"] = aspect }
            result["type"] = "perspective"
            result["perspective"] = perspective
        }
        return result
    }

    static func decodeLight(_ source: GLTFDocument.PunctualLight) throws(SceneFormatError) -> Light {
        let color = source.color ?? [1, 1, 1]
        let strength = source.intensity ?? 1
        guard color.count == 3, color.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              strength.isFinite, strength >= 0, (strength * 1000).isFinite,
              source.range.map({ $0.isFinite && $0 > 0 }) ?? true else {
            throw .malformed("Invalid punctual light color, intensity or range", offset: nil)
        }
        let kind: LightDescriptor.Kind
        switch source.type {
        case "point": kind = .omni
        case "directional": kind = .directional
        case "spot": kind = .spot
        default: throw .malformed("Unknown punctual light type", offset: nil)
        }
        guard kind != .directional || source.range == nil,
              kind == .spot || source.spot == nil else {
            throw .malformed("Punctual light properties do not match its type", offset: nil)
        }
        var descriptor = LightDescriptor(kind: kind, color: SIMD3(color[0], color[1], color[2]),
            intensity: strength * 1000, attenuationEndDistance: source.range ?? 0, falloffModel: .inverseSquare)
        if kind == .spot {
            guard let spot = source.spot else { throw .malformed("Spot light requires a spot object", offset: nil) }
            let inner = spot.innerConeAngle ?? 0
            let outer = spot.outerConeAngle ?? (.pi / 4)
            guard inner.isFinite, outer.isFinite, inner >= 0, outer > inner, outer <= .pi / 2 else {
                throw .malformed("Invalid spot cone angles", offset: nil)
            }
            descriptor.spotInnerAngle = inner * 360 / .pi
            descriptor.spotOuterAngle = outer * 360 / .pi
        }
        let light = Light(descriptor)
        light.name = source.name
        return light
    }

    static func encodeLight(_ light: Light) throws(SceneFormatError) -> [String: Any] {
        let l = light.descriptor
        guard l.kind != .ambient else { throw .unsupported("glTF has no ambient light; use --geometry-only to omit lights") }
        guard l.temperature == 6500, !l.castsShadow, l.attenuationStartDistance == 0,
              l.attenuationFalloffExponent == 2 else {
            throw .unsupported("GLB light temperature, shadows or custom attenuation; use --geometry-only to omit lights")
        }
        let color = [l.color.x, l.color.y, l.color.z]
        guard color.allSatisfy({ $0.isFinite && (0...1).contains($0) }), l.intensity.isFinite, l.intensity >= 0,
              l.attenuationEndDistance.isFinite, l.attenuationEndDistance >= 0 else {
            throw .malformed("Invalid light color, intensity or range", offset: nil)
        }
        var result: [String: Any] = ["type": l.kind == .directional ? "directional" : l.kind == .omni ? "point" : "spot",
                                   "color": color, "intensity": l.intensity / 1000]
        if let name = light.name { result["name"] = name }
        if l.attenuationEndDistance > 0 {
            guard l.kind != .directional else { throw .unsupported("Directional glTF lights cannot have a range") }
            result["range"] = l.attenuationEndDistance
        }
        if l.kind == .spot {
            guard l.spotInnerAngle.isFinite, l.spotOuterAngle.isFinite,
                  l.spotInnerAngle >= 0, l.spotInnerAngle < l.spotOuterAngle, l.spotOuterAngle <= 180 else {
                throw .malformed("Invalid spot cone angles", offset: nil)
            }
            result["spot"] = ["innerConeAngle": l.spotInnerAngle * .pi / 360,
                              "outerConeAngle": l.spotOuterAngle * .pi / 360]
        }
        return result
    }
}
