import SceneCore
import SceneFormats

extension USDMaterialReader {
    enum TextureSlot { case diffuse, unlit, emission, metallicRoughness, normal, occlusion }

    /// Reads supported UV0 texture graphs. Assets stay inside the archive.
    func texture(_ surface: USDPrim, slot: TextureSlot, opacity: Float = 1) throws(SceneFormatError)
        -> (property: MaterialProperty, factor: SIMD4<Float>, usesAlpha: Bool) {
        guard let archive, let layer = archive.defaultLayer else {
            throw .unsupported("USD textures require a USDZ package")
        }
        let input: String
        switch slot {
        case .diffuse: input = "inputs:diffuseColor.connect"
        case .emission, .unlit: input = "inputs:emissiveColor.connect"
        case .metallicRoughness: input = "inputs:metallic.connect"
        case .normal: input = "inputs:normal.connect"
        case .occlusion: input = "inputs:occlusion.connect"
        }
        guard let colorConnection = try USDRead.attribute(surface, input, types: [(slot == .metallicRoughness || slot == .occlusion) ? "float" : (slot == .normal ? "normal3f" : "color3f")]) else {
            throw USDRead.invalid("Missing USD color texture connection")
        }
        let path = try target(colorConnection)
        let suffix = slot == .metallicRoughness ? ".outputs:b" : (slot == .occlusion ? ".outputs:r" : ".outputs:rgb")
        guard path.hasSuffix(suffix) else { throw .unsupported("Unsupported USD texture output channel") }
        let texturePath = String(path.dropLast(suffix.count))
        if slot == .metallicRoughness {
            guard let roughness = try USDRead.attribute(surface, "inputs:roughness.connect", types: ["float"]),
                  try target(roughness) == texturePath + ".outputs:g" else {
                throw .unsupported("USD roughness must use the shared metallic texture green channel")
            }
        }
        let texture = try activePrim(at: texturePath, type: "Shader")
        guard try USDRead.attribute(texture, "info:id", types: ["token"]) == .string("UsdUVTexture") else {
            throw .unsupported("USD color source must be UsdUVTexture")
        }
        let allowed: Set<String> = ["info:id", "inputs:file", "inputs:st.connect", "inputs:sourceColorSpace",
            "inputs:wrapS", "inputs:wrapT", "inputs:scale", "inputs:bias", "outputs:rgb", "outputs:a", "outputs:g", "outputs:b", "outputs:r"]
        guard texture.properties.allSatisfy({ allowed.contains($0.name) }) else {
            throw .unsupported("USD texture graph has unsupported inputs")
        }
        guard try USDRead.attribute(texture, "inputs:sourceColorSpace", types: ["token"]) == .string((slot == .metallicRoughness || slot == .normal || slot == .occlusion) ? "raw" : "sRGB") else {
            throw .unsupported("USD color textures require sRGB and packed data textures require raw color space")
        }
        let biasValues: [Float]
        if let bias = try USDRead.attribute(texture, "inputs:bias", types: ["float4"]) {
            biasValues = try USDRead.tuple(bias, count: 4)
        } else { biasValues = [0,0,0,0] }
        if slot != .normal, slot != .occlusion, biasValues != [0,0,0,0] { throw .unsupported("USD texture bias") }
        let scaleValues: [Float]
        if let scale = try USDRead.attribute(texture, "inputs:scale", types: ["float4"]) {
            scaleValues = try USDRead.tuple(scale, count: 4)
        } else { scaleValues = [1,1,1,1] }
        let normalStrength: Float
        if slot == .normal {
            normalStrength = scaleValues[0] / 2
            guard normalStrength >= 0, abs(scaleValues[1]) == scaleValues[0], scaleValues[2] == 2,
                  scaleValues[3] == 1, biasValues == [-normalStrength, -scaleValues[1] / 2, -1, 0] else {
                throw .unsupported("USD normal map requires signed RGB decoding with uniform XY strength")
            }
        } else {
            normalStrength = 1
            guard scaleValues.prefix(3).allSatisfy({ $0 >= 0 && (slot == .emission || $0 <= 1) }),
                  (0...1).contains(scaleValues[3]) else { throw USDRead.invalid("USD texture scale outside supported range") }
        }
        if slot == .occlusion {
            guard scaleValues[1...3].allSatisfy({ $0 == 1 }),
                  biasValues == [1 - scaleValues[0], 0, 0, 0] else {
                throw .unsupported("USD occlusion requires red-channel strength scale and complementary bias")
            }
        }
        guard let st = try USDRead.attribute(texture, "inputs:st.connect", types: ["float2"]) else {
            throw .unsupported("USD texture requires UV primvar connection")
        }
        let uvPath = try target(st)
        guard uvPath.hasSuffix(".outputs:result") else { throw .unsupported("USD texture coordinate output") }
        let reader = try activePrim(at: String(uvPath.dropLast(".outputs:result".count)), type: "Shader")
        guard try USDRead.attribute(reader, "info:id", types: ["token"]) == .string("UsdPrimvarReader_float2"),
              try USDRead.attribute(reader, "inputs:varname", types: ["string", "token"]) == .string("st"),
              reader.properties.allSatisfy({ ["info:id", "inputs:varname", "outputs:result"].contains($0.name) }) else {
            throw .unsupported("USD texture requires a direct st primvar reader")
        }
        let alphaConnection = (slot != .diffuse && slot != .unlit) ? nil : try USDRead.attribute(surface, "inputs:opacity.connect", types: ["float"])
        if let alphaConnection, try target(alphaConnection) != texturePath + ".outputs:a" {
            throw .unsupported("USD opacity must use the diffuse texture alpha")
        }
        guard let file = try USDRead.attribute(texture, "inputs:file", types: ["asset"]), case .asset(let assetPath) = file else {
            throw USDRead.invalid("USD texture requires an asset file")
        }
        let entryPath = try packagePath(assetPath, relativeTo: layer.path)
        guard let entry = archive[entryPath] else { throw USDRead.invalid("Missing USDZ texture \(entryPath)") }
        var image = try TextureImageLoader.decodeImage(Array(entry.data))
        // Constant opacity is independent of image alpha. Clear it before ordinary material blending.
        if slot == .diffuse || slot == .unlit, alphaConnection == nil {
            for y in 0..<image.height {
                for x in 0..<image.width { image.pixels[y * image.bytesPerRow + x * 4 + 3] = 255 }
            }
        }
        if slot == .normal, scaleValues[1] > 0 {
            // Standard USD +Y tangent normals become -Y when UV V is converted for the engine.
            for y in 0..<image.height {
                for x in 0..<image.width {
                    let offset = y * image.bytesPerRow + x * 4 + 1
                    image.pixels[offset] = 255 - image.pixels[offset]
                }
            }
        }
        var property = MaterialProperty.texture(.image(image))
        if slot == .normal { property.intensity = normalStrength }
        if slot == .occlusion { property.intensity = scaleValues[0] }
        property.sampler.wrapS = try wrap(texture, name: "inputs:wrapS")
        property.sampler.wrapT = try wrap(texture, name: "inputs:wrapT")
        return (property, SIMD4(scaleValues[0], scaleValues[1], scaleValues[2], alphaConnection == nil ? opacity : scaleValues[3]), alphaConnection != nil)
    }

    private func wrap(_ texture: USDPrim, name: String) throws(SceneFormatError) -> TextureWrapMode {
        let value = try USDRead.attribute(texture, name, types: ["token"]) ?? .string("black")
        switch try USDRead.string(value) {
        case "clamp": return .clamp
        case "repeat": return .repeat
        case "mirror": return .mirror
        case "black": return .clampToBorder
        default: throw .unsupported("USD texture metadata wrapping")
        }
    }

    private func packagePath(_ asset: String, relativeTo layer: String) throws(SceneFormatError) -> String {
        guard !asset.isEmpty, !asset.hasPrefix("/"), !asset.contains(":"), !asset.contains("\\"),
              !asset.contains("["), !asset.contains("]") else {
            throw .unsupported("USD texture must be a relative package member")
        }
        var components = layer.split(separator: "/").dropLast().map(String.init)
        for component in asset.split(separator: "/", omittingEmptySubsequences: false) {
            if component == "." { continue }
            if component == ".." {
                guard !components.isEmpty else { throw USDRead.invalid("USD texture escapes package") }
                components.removeLast()
            } else {
                guard !component.isEmpty else { throw USDRead.invalid("Empty USD texture path component") }
                components.append(String(component))
            }
        }
        return components.joined(separator: "/")
    }
}
