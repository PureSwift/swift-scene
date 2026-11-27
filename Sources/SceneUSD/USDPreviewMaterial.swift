import SceneCore
import SceneFormats

/// Constant inputs for the metallic workflow. Legacy lighting is approximated as rough dielectric.
struct USDPreviewMaterial {
    let diffuse: SIMD3<Float>
    let emission: SIMD3<Float>
    let metallic: Float
    let roughness: Float
    let opacity: Float
    let opacityThreshold: Float

    init(_ material: MaterialDescriptor, nodeOpacity: Float = 1) throws(SceneFormatError) {
        guard material.cullMode == .back, material.blendMode == .alpha,
              material.writesToDepthBuffer, material.readsFromDepthBuffer else {
            throw .unsupported("USD custom culling, blending or depth state; opt into geometryOnly")
        }
        guard material.normal.contents == .none, material.ambientOcclusion.contents == .none,
              material.transparent.contents == .none else {
            throw .unsupported("USD normal, occlusion or transparency maps; opt into geometryOnly")
        }
        guard [material.diffuseFactor.x, material.diffuseFactor.y, material.diffuseFactor.z, material.diffuseFactor.w,
               material.metalnessFactor, material.roughnessFactor].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              [material.emissionFactor.x, material.emissionFactor.y, material.emissionFactor.z].allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw USDRead.invalid("Invalid USD material multipliers")
        }
        // Validate even legacy inputs that have no exact PBR equivalent, rather than silently losing textures.
        _ = try Self.color(material.ambient)
        _ = try Self.color(material.specular)
        let base = try Self.color(material.diffuse) * material.diffuseFactor
        let glow = try Self.color(material.emission)
        let emission = SIMD3(glow.x, glow.y, glow.z) * material.emissionFactor
        let metal = try Self.scalar(material.metalness) * material.metalnessFactor
        let rough = try Self.scalar(material.roughness) * material.roughnessFactor
        guard [base.x, base.y, base.z, base.w, metal, rough, material.transparency].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              [emission.x, emission.y, emission.z].allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw USDRead.invalid("Invalid USD material factors")
        }
        let rgb = SIMD3(base.x, base.y, base.z)
        if material.lightingModel == .unlit {
            // Preview Surface has no unlit mode. Emission with ior=1 suppresses the specular lobe.
            diffuse = .zero
            self.emission = rgb + emission
        } else {
            diffuse = rgb
            self.emission = emission
        }
        metallic = material.lightingModel == .physicallyBased ? metal : 0
        roughness = material.lightingModel == .physicallyBased ? rough : 1
        switch material.alphaMode {
        case .opaque: opacity = 1; opacityThreshold = 0
        case .legacy, .blend: opacity = base.w * material.transparency * nodeOpacity; opacityThreshold = 0
        case .mask(let cutoff):
            guard cutoff.isFinite, cutoff > 0, cutoff <= 1 else {
                throw .unsupported("USD opacity mask cutoff must be in (0, 1]")
            }
            opacity = base.w * material.transparency * nodeOpacity
            opacityThreshold = cutoff
        }
        guard [self.emission.x, self.emission.y, self.emission.z].allSatisfy({ $0.isFinite }) else {
            throw USDRead.invalid("USD emission overflow")
        }
    }

    private static func color(_ property: MaterialProperty) throws(SceneFormatError) -> SIMD4<Float> {
        guard property.intensity == 1 else { throw .unsupported("USD material property intensity; opt into geometryOnly") }
        switch property.contents {
        case .none: return SIMD4(0, 0, 0, 1)
        case .color(let color):
            guard [color.x, color.y, color.z, color.w].allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                throw USDRead.invalid("Invalid USD material color")
            }
            return color
        case .scalar(let value):
            guard value.isFinite, value >= 0 else { throw USDRead.invalid("Invalid USD material scalar") }
            return SIMD4(value, value, value, 1)
        case .texture: throw .unsupported("USD texture export; opt into geometryOnly")
        }
    }

    private static func scalar(_ property: MaterialProperty) throws(SceneFormatError) -> Float {
        guard case .scalar(let value) = property.contents, property.intensity == 1, value.isFinite, (0...1).contains(value) else {
            throw .unsupported("USD metallic/roughness inputs must be scalar constants in 0...1")
        }
        return value
    }
}
