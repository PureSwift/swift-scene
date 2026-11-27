import SceneCore
import SceneFormats

extension USDMaterialReader {
    /// Reads only the UV0 -> UsdUVTexture -> diffuse/alpha or emissive graph. Assets stay inside the archive.
    func colorTexture(_ surface: USDPrim, opacity: Float, isEmission: Bool = false) throws(SceneFormatError)
        -> (property: MaterialProperty, factor: SIMD4<Float>, usesAlpha: Bool) {
        guard let archive, let layer = archive.defaultLayer else {
            throw .unsupported("USD textures require a USDZ package")
        }
        guard let colorConnection = try USDRead.attribute(surface, isEmission ? "inputs:emissiveColor.connect" : "inputs:diffuseColor.connect", types: ["color3f"]) else {
            throw USDRead.invalid("Missing USD color texture connection")
        }
        let path = try target(colorConnection)
        let suffix = ".outputs:rgb"
        guard path.hasSuffix(suffix) else { throw .unsupported("USD color texture must use RGB output") }
        let texturePath = String(path.dropLast(suffix.count))
        let texture = try activePrim(at: texturePath, type: "Shader")
        guard try USDRead.attribute(texture, "info:id", types: ["token"]) == .string("UsdUVTexture") else {
            throw .unsupported("USD color source must be UsdUVTexture")
        }
        let allowed: Set<String> = ["info:id", "inputs:file", "inputs:st.connect", "inputs:sourceColorSpace",
            "inputs:wrapS", "inputs:wrapT", "inputs:scale", "inputs:bias", "outputs:rgb", "outputs:a"]
        guard texture.properties.allSatisfy({ allowed.contains($0.name) }) else {
            throw .unsupported("USD texture graph has unsupported inputs")
        }
        guard try USDRead.attribute(texture, "inputs:sourceColorSpace", types: ["token"]) == .string("sRGB") else {
            throw .unsupported("USD color textures require explicit sRGB color space")
        }
        if let bias = try USDRead.attribute(texture, "inputs:bias", types: ["float4"]),
           try USDRead.tuple(bias, count: 4) != [0,0,0,0] {
            throw .unsupported("USD texture bias")
        }
        let scaleValues: [Float]
        if let scale = try USDRead.attribute(texture, "inputs:scale", types: ["float4"]) {
            scaleValues = try USDRead.tuple(scale, count: 4)
        } else { scaleValues = [1,1,1,1] }
        guard scaleValues.prefix(3).allSatisfy({ $0 >= 0 && (isEmission || $0 <= 1) }),
              (0...1).contains(scaleValues[3]) else { throw USDRead.invalid("USD texture scale outside supported range") }
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
        let alphaConnection = isEmission ? nil : try USDRead.attribute(surface, "inputs:opacity.connect", types: ["float"])
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
        if !isEmission, alphaConnection == nil {
            for y in 0..<image.height {
                for x in 0..<image.width { image.pixels[y * image.bytesPerRow + x * 4 + 3] = 255 }
            }
        }
        var property = MaterialProperty.texture(.image(image))
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
