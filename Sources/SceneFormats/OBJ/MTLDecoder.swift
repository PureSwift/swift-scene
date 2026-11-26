import SceneCore

/// Reads a Wavefront material library (`.mtl`): the materials an OBJ file names with `usemtl`.
///
/// Phong's colours (`Ka`, `Kd`, `Ks`, `Ke`), shininess (`Ns`), transparency (`d`, or `Tr` its complement), the
/// illumination model (`illum`), texture maps (`map_Kd`, `map_Ks`, `map_Ke`, `map_d`, `map_Bump`/`bump`/`norm`), and
/// the PBR extension's roughness and metalness (`Pr`, `Pm`, `map_Pr`, `map_Pm`). Texture paths are resolved
/// against `baseDirectory` when they're relative; their options (`-s`, `-o`, `-clamp`, …) are read for the scale
/// and clamping and otherwise skipped.
public struct MTLDecoder {

    /// Where relative texture paths are from: the library's directory.
    public var baseDirectory: String?

    public init(baseDirectory: String? = nil) {
        self.baseDirectory = baseDirectory
    }

    /// The library's materials, by name.
    public func decode(_ bytes: [UInt8]) -> [String: MaterialDescriptor] {
        var reader = OBJLineReader(bytes)
        var materials: [String: MaterialDescriptor] = [:]
        var name: String?
        var current = MaterialDescriptor()
        // Whether the material says how it's lit: PBR values make it physically based unless `illum` says otherwise.
        var illumination: Int?
        var isPhysicallyBased = false

        func finish() {
            guard let name else { return }
            var material = current
            material.name = name
            if isPhysicallyBased, illumination == nil || illumination! > 2 {
                material.lightingModel = .physicallyBased
            }
            materials[name] = material
        }

        while reader.nextLine() {
            guard let keyword = reader.keyword() else { continue }
            switch keyword {
            case "newmtl":
                finish()
                name = reader.rest()
                current = MaterialDescriptor(lightingModel: .phong)
                illumination = nil
                isPhysicallyBased = false
            case "Kd":
                if let color = color(&reader) { current.diffuse = .color(SIMD4(color, current.diffuse.color?.w ?? 1)) }
            case "Ka":
                if let color = color(&reader) { current.ambient = .color(SIMD4(color, 1)) }
            case "Ks":
                if let color = color(&reader) { current.specular = .color(SIMD4(color, 1)) }
            case "Ke":
                if let color = color(&reader) { current.emission = .color(SIMD4(color, 1)) }
            case "Ns":
                // A specular exponent, 0 to 1000; the shininess scales to one by 128.
                if let exponent = reader.number() { current.shininess = max(exponent, 1) / 128 }
            case "d":
                if let value = reader.number() { current.transparency = min(max(value, 0), 1) }
            case "Tr":
                if let value = reader.number() { current.transparency = 1 - min(max(value, 0), 1) }
            case "illum":
                guard let model = reader.integer() else { break }
                illumination = model
                switch model {
                case 0: current.lightingModel = .unlit
                case 1: current.lightingModel = .lambert
                default: current.lightingModel = .phong
                }
            case "Pr":
                if let value = reader.number() {
                    current.roughness = .scalar(value)
                    isPhysicallyBased = true
                }
            case "Pm":
                if let value = reader.number() {
                    current.metalness = .scalar(value)
                    isPhysicallyBased = true
                }
            case "map_Kd":
                if let map = texture(&reader) { current.diffuse = map }
            case "map_Ks":
                if let map = texture(&reader) { current.specular = map }
            case "map_Ke":
                if let map = texture(&reader) { current.emission = map }
            case "map_d":
                if let map = texture(&reader) { current.transparent = map }
            case "map_Bump", "map_bump", "bump", "norm":
                if let map = texture(&reader) { current.normal = map }
            case "map_Pr":
                if let map = texture(&reader) {
                    current.roughness = map
                    isPhysicallyBased = true
                }
            case "map_Pm":
                if let map = texture(&reader) {
                    current.metalness = map
                    isPhysicallyBased = true
                }
            default:
                break
            }
        }
        finish()
        return materials
    }

    /// `r g b`, or one value for all three; `spectral` and `xyz` colours aren't read.
    private func color(_ reader: inout OBJLineReader) -> SIMD3<Float>? {
        let values = reader.numbers(upTo: 3)
        switch values.count {
        case 3: return SIMD3(values[0], values[1], values[2])
        case 1: return SIMD3(repeating: values[0])
        default: return nil
        }
    }

    /// A texture map: options, then the path, which may have spaces.
    private func texture(_ reader: inout OBJLineReader) -> MaterialProperty? {
        var sampler = TextureSampler(wrapS: .repeat, wrapT: .repeat, mipFilter: .linear)
        var scale = SIMD2<Float>(1, 1), offset = SIMD2<Float>(0, 0)
        // Each option and how many values may follow it. Word options take one word; numeric ones take numbers up
        // to the count, since later ones may be left out.
        let options: [String: Int] = [
            "-blendu": 1, "-blendv": 1, "-boost": 1, "-mm": 2, "-o": 3, "-s": 3, "-t": 3, "-texres": 1,
            "-clamp": 1, "-bm": 1, "-imfchan": 1, "-type": 1, "-cc": 1,
        ]
        let wordOptions: Set<String> = ["-blendu", "-blendv", "-clamp", "-imfchan", "-type", "-cc"]
        let words = reader.rest().split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var i = 0
        while i < words.count, let count = options[words[i]] {
            let option = words[i]
            i += 1
            var values: [String] = []
            while values.count < count, i < words.count, wordOptions.contains(option) || Float(words[i]) != nil {
                values.append(words[i])
                i += 1
            }
            let numbers = values.compactMap { Float($0) }
            switch option {
            case "-s" where numbers.count >= 2: scale = SIMD2(numbers[0], numbers[1])
            case "-o" where numbers.count >= 2: offset = SIMD2(numbers[0], numbers[1])
            case "-clamp" where values.first == "on":
                sampler.wrapS = .clamp
                sampler.wrapT = .clamp
            default: break
            }
        }
        let path = words[i...].joined(separator: " ")
        guard !path.isEmpty else { return nil }
        var property = MaterialProperty(.texture(.path(resolve(path))), sampler: sampler)
        if scale != SIMD2(1, 1) || offset != .zero {
            var transform = Matrix4x4(scale: SIMD3(scale, 1))
            transform.translation = SIMD3(offset, 0)
            property.contentsTransform = transform
        }
        return property
    }

    private func resolve(_ path: String) -> String {
        let path = path.replacingBackslashes()
        guard let baseDirectory, !baseDirectory.isEmpty, !path.hasPrefix("/") else { return path }
        return baseDirectory.hasSuffix("/") ? baseDirectory + path : baseDirectory + "/" + path
    }
}

extension String {

    /// The path with Windows separators as Unix ones, as many OBJ files written on Windows have.
    func replacingBackslashes() -> String {
        String(map { $0 == "\\" ? "/" : $0 })
    }
}
