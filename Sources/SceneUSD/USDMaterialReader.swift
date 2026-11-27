import SceneCore
import SceneFormats

/// Resolves direct bindings to Preview Surface constants and packaged color textures.
/// No arbitrary shader evaluation, external asset loading or composition is performed.
struct USDMaterialReader {
    let stage: USDStage
    let archive: USDZArchive?

    func binding(on prim: USDPrim, inherited: MaterialDescriptor?) throws(SceneFormatError) -> MaterialDescriptor? {
        for property in prim.properties where property.name.hasPrefix("material:binding") {
            guard property.name == "material:binding", property.kind == .relationship else {
                throw .unsupported("USD collection or purpose-specific material binding")
            }
        }
        guard let binding = prim[property: "material:binding"] else { return inherited }
        if let strength = binding.metadata["bindMaterialAs"], strength != .string("weakerThanDescendants") {
            throw .unsupported("USD stronger-than-descendants material binding")
        }
        guard let value = binding.value else { return inherited }
        let path = try target(value)
        let material = try activePrim(at: path, type: "Material")
        for property in material.properties {
            guard property.name == "outputs:surface.connect" else {
                throw .unsupported("USD material interface or additional output: \(property.name)")
            }
        }
        guard let connection = try USDRead.attribute(material, "outputs:surface.connect", types: ["token"]) else {
            throw USDRead.invalid("USD material has no surface connection")
        }
        let shaderOutput = try target(connection)
        let suffix = ".outputs:surface"
        guard shaderOutput.hasSuffix(suffix) else { throw .unsupported("USD material surface output") }
        let shader = try activePrim(at: String(shaderOutput.dropLast(suffix.count)), type: "Shader")
        var descriptor = try preview(shader)
        descriptor.name = try USDRead.string(material.metadata["displayName"] ?? .string(material.name))
        return descriptor
    }

    func target(_ value: USDValue) throws(SceneFormatError) -> String {
        let single: USDValue
        if case .array(let values) = value {
            guard values.count == 1 else { throw .unsupported("USD binding requires exactly one target") }
            single = values[0]
        } else { single = value }
        guard case .path(let path) = single, path.hasPrefix("/"), !path.contains("..") else {
            throw .unsupported("USD material targets must be absolute paths")
        }
        return path
    }

    func activePrim(at path: String, type: String) throws(SceneFormatError) -> USDPrim {
        var ancestor = ""
        for component in path.split(separator: "/") {
            ancestor += "/" + component
            guard let prim = stage.prim(at: ancestor) else { throw USDRead.invalid("Missing USD material target \(path)") }
            if let active = prim.metadata["active"], try !USDRead.boolean(active) {
                throw USDRead.invalid("Inactive USD material target \(path)")
            }
            if let instanceable = prim.metadata["instanceable"], try USDRead.boolean(instanceable) {
                throw .unsupported("USD instanced material target")
            }
        }
        guard let prim = stage.prim(at: path), prim.typeName == type else {
            throw USDRead.invalid("USD material target must be a \(type)")
        }
        return prim
    }

    private func preview(_ shader: USDPrim) throws(SceneFormatError) -> MaterialDescriptor {
        guard try USDRead.attribute(shader, "info:id", types: ["token"]) == .string("UsdPreviewSurface") else {
            throw .unsupported("USD shader is not UsdPreviewSurface")
        }
        let allowed: Set<String> = ["info:id", "outputs:surface", "inputs:diffuseColor", "inputs:emissiveColor",
            "inputs:metallic", "inputs:roughness", "inputs:opacity", "inputs:opacityThreshold", "inputs:ior",
            "inputs:useSpecularWorkflow", "inputs:clearcoat", "inputs:displacement", "inputs:occlusion", "inputs:normal",
            "inputs:diffuseColor.connect", "inputs:opacity.connect", "inputs:emissiveColor.connect", "inputs:metallic.connect", "inputs:roughness.connect", "inputs:normal.connect"]
        for property in shader.properties where !allowed.contains(property.name) {
            throw .unsupported("USD shader input or connection: \(property.name); opt into geometryOnly")
        }
        func scalar(_ name: String, _ fallback: Float, type: String = "float") throws(SceneFormatError) -> Float {
            guard let value = try USDRead.attribute(shader, "inputs:" + name, types: [type]) else { return fallback }
            return try USDRead.scalar(value)
        }
        func color(_ name: String, _ fallback: SIMD3<Float>, type: String = "color3f") throws(SceneFormatError) -> SIMD3<Float> {
            guard let value = try USDRead.attribute(shader, "inputs:" + name, types: [type]) else { return fallback }
            let values = try USDRead.tuple(value, count: 3)
            return SIMD3(values[0], values[1], values[2])
        }
        guard try scalar("useSpecularWorkflow", 0, type: "int") == 0,
              try scalar("clearcoat", 0) == 0, try scalar("displacement", 0) == 0, try scalar("occlusion", 1) == 1,
              try color("normal", SIMD3(0,0,1), type: "normal3f") == SIMD3(0,0,1) else {
            throw .unsupported("USD specular workflow, clearcoat, displacement, occlusion or normal input")
        }
        let diffuse = try color("diffuseColor", SIMD3(repeating: 0.18))
        let emission = try color("emissiveColor", .zero)
        let metal = try scalar("metallic", 0), roughness = try scalar("roughness", 0.5)
        let opacity = try scalar("opacity", 1), threshold = try scalar("opacityThreshold", 0)
        let ior = try scalar("ior", 1.5)
        guard [diffuse.x, diffuse.y, diffuse.z, metal, roughness, opacity, threshold].allSatisfy({ (0...1).contains($0) }),
              [emission.x, emission.y, emission.z].allSatisfy({ $0 >= 0 }) else {
            throw USDRead.invalid("USD Preview Surface values outside supported range")
        }
        var result = MaterialDescriptor.physicallyBased(baseColor: SIMD4(diffuse.x, diffuse.y, diffuse.z, opacity),
                                                       metalness: metal, roughness: roughness)
        result.emission = .color(SIMD4(emission.x, emission.y, emission.z, 1))
        if ior == 1, diffuse == .zero, metal == 0 {
            // Recognize the exporter's emission-only approximation, retaining the visible color.
            result.lightingModel = .unlit
            result.diffuse = .color(SIMD4(emission.x, emission.y, emission.z, opacity))
            result.emission = .color(SIMD4(0,0,0,1))
        } else if ior != 1.5 { throw .unsupported("USD nondefault index of refraction") }
        result.alphaMode = threshold > 0 ? .mask(cutoff: threshold) : (opacity < 1 ? .blend : .opaque)
        if shader[property: "inputs:diffuseColor.connect"] != nil {
            guard ior == 1.5 else { throw .unsupported("USD textured material IOR") }
            let texture = try self.texture(shader, slot: .diffuse, opacity: opacity)
            result.diffuse = texture.property
            result.diffuseFactor = texture.factor
            if texture.usesAlpha, threshold == 0 { result.alphaMode = .blend }
        } else if shader[property: "inputs:opacity.connect"] != nil {
            throw .unsupported("USD opacity texture requires a shared diffuse texture")
        }
        if shader[property: "inputs:emissiveColor.connect"] != nil {
            guard ior == 1.5 else { throw .unsupported("USD textured material IOR") }
            let texture = try self.texture(shader, slot: .emission)
            result.emission = texture.property
            result.emissionFactor = SIMD3(texture.factor.x, texture.factor.y, texture.factor.z)
        }
        if shader[property: "inputs:metallic.connect"] != nil || shader[property: "inputs:roughness.connect"] != nil {
            guard ior == 1.5 else { throw .unsupported("USD textured material IOR") }
            let packed = try self.texture(shader, slot: .metallicRoughness)
            result.metalness = packed.property
            result.roughness = packed.property
            result.metalnessFactor = packed.factor.z
            result.roughnessFactor = packed.factor.y
        }
        if shader[property: "inputs:normal.connect"] != nil {
            guard ior == 1.5 else { throw .unsupported("USD textured material IOR") }
            result.normal = try self.texture(shader, slot: .normal).property
        }
        return result
    }
}
