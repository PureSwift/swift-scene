import Foundation
import SceneCore
import SceneFormats
import SceneGraph

/// Shared validation for zero-angle distant lights and normalized point-source approximations.
enum USDDistantLight {
    static func attributes(_ light: Light, point: Bool = false) throws(SceneFormatError) -> [String] {
        let l = light.descriptor
        guard l.kind == (point ? .omni : .directional) else { throw .unsupported("USD export supports directional and inverse-square point lights") }
        if point, l.falloffModel != .inverseSquare { throw .unsupported("USD point lights require inverse-square falloff") }
        guard l.temperature == 6500, !l.castsShadow, l.attenuationStartDistance == 0,
              l.attenuationEndDistance == 0, l.attenuationFalloffExponent == 2 else {
            throw .unsupported("USD light temperature, shadows or attenuation")
        }
        guard l.intensity.isFinite, l.intensity >= 0,
              [l.color.x,l.color.y,l.color.z].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw USDRead.invalid("Invalid USD light color or intensity")
        }
        var attributes = [
            "color3f inputs:color = (\(l.color.x), \(l.color.y), \(l.color.z))",
            "float inputs:intensity = \(l.intensity / 1000)",
            "float inputs:exposure = 0",
            "bool inputs:normalize = true",
            "bool inputs:enableColorTemperature = false",
            "bool inputs:shadow:enable = false"
        ]
        attributes += point ? ["bool treatAsPoint = true", "float inputs:radius = 0"] : ["float inputs:angle = 0"]
        return attributes
    }

    static func decode(_ prim: USDPrim, point: Bool = false) throws(SceneFormatError) -> Light {
        var allowed: Set<String> = ["inputs:color", "inputs:intensity", "inputs:exposure", "inputs:normalize",
            "inputs:enableColorTemperature", "inputs:colorTemperature", "inputs:shadow:enable",
            "inputs:diffuse", "inputs:specular", "visibility", "purpose"]
        allowed.formUnion(point ? ["treatAsPoint", "inputs:radius"] : ["inputs:angle"])
        for property in prim.properties {
            guard allowed.contains(property.name) || property.name.hasPrefix("xformOp") else {
                throw .unsupported("USD light property \(property.name)")
            }
        }
        func scalar(_ name: String, _ fallback: Float) throws(SceneFormatError) -> Float {
            try USDRead.scalar(USDRead.attribute(prim, name, types: ["float"]) ?? .number(String(fallback)))
        }
        func boolean(_ name: String, _ fallback: Bool) throws(SceneFormatError) -> Bool {
            try USDRead.boolean(USDRead.attribute(prim, name, types: ["bool"]) ?? .boolean(fallback))
        }
        if point {
            guard try boolean("treatAsPoint", false), try boolean("inputs:normalize", false),
                  try scalar("inputs:radius", 0.5) == 0 else {
                throw .unsupported("USD point lights require treatAsPoint, normalization and zero radius")
            }
        } else {
            guard try scalar("inputs:angle", 0.53) == 0 else { throw .unsupported("USD distant light angular extent") }
        }
        guard try scalar("inputs:diffuse", 1) == 1, try scalar("inputs:specular", 1) == 1,
              try !boolean("inputs:enableColorTemperature", false),
              try !boolean("inputs:shadow:enable", true) else {
            throw .unsupported("USD lights require no shadows/temperature and default contributions")
        }
        // At zero angle the normalization size factor is one in either mode.
        _ = try boolean("inputs:normalize", false)
        _ = try scalar("inputs:colorTemperature", 6500)
        let values = try USDRead.tuple(USDRead.attribute(prim, "inputs:color", types: ["color3f"]) ??
            .tuple([.number("1"), .number("1"), .number("1")]), count: 3)
        let intensity = try scalar("inputs:intensity", point ? 1 : 50000)
        let exposure = try scalar("inputs:exposure", 0)
        let strength = Double(intensity) * pow(2, Double(exposure)) * 1000
        guard intensity >= 0, strength.isFinite, strength <= Double(Float.greatestFiniteMagnitude),
              values.allSatisfy({ (0...1).contains($0) }) else { throw USDRead.invalid("Invalid USD light strength or color") }
        let light = Light(LightDescriptor(kind: point ? .omni : .directional, color: SIMD3(values[0],values[1],values[2]),
                                          intensity: Float(strength), falloffModel: .inverseSquare))
        light.name = try USDRead.string(prim.metadata["displayName"] ?? .string(prim.name))
        return light
    }
}
