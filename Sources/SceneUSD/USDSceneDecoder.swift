import SceneCore
import SceneFormats
import SceneGraph

/// Imports standalone static USDA (including USDA inside USDZ) into a Y-up, metre-based scene.
/// Supports static geometry and Preview Surface materials, including packaged diffuse and emissive textures.
public struct USDSceneDecoder: SceneAssetDecoder {
    public static let fileExtensions = ["usda", "usd", "usdz"]

    /// Explicitly discard material bindings and shading prims, using a default surface material.
    public var geometryOnly: Bool

    public init(geometryOnly: Bool = false) { self.geometryOnly = geometryOnly }

    public func decode(_ data: [UInt8]) async throws(SceneFormatError) -> Scene {
        try decodeScene(data)
    }

    public func decodeScene(_ data: [UInt8]) throws(SceneFormatError) -> Scene {
        if data.prefix(4).elementsEqual([0x50, 0x4b, 3, 4]) {
            let archive = try USDZArchive(data)
            return try decodeScene(USDStage(archive: archive), archive: archive)
        }
        if data.prefix(8).elementsEqual(Array("PXR-USDC".utf8)) { throw .unsupported("USDC Crate layers") }
        return try decodeScene(USDStage(usda: data))
    }

    public func decodeScene(_ stage: USDStage) throws(SceneFormatError) -> Scene {
        try decodeScene(stage, archive: nil)
    }

    private func decodeScene(_ stage: USDStage, archive: USDZArchive?) throws(SceneFormatError) -> Scene {
        let scene = Scene()
        let units = try USDRead.scalar(stage.metadata["metersPerUnit"] ?? .number("0.01"))
        guard units > 0 else { throw USDRead.invalid("metersPerUnit must be positive") }
        let axis = try USDRead.string(stage.metadata["upAxis"] ?? .string("Y"))
        guard axis == "Y" || axis == "Z" else { throw USDRead.invalid("Invalid USD upAxis") }
        let rotation = axis == "Z" ? Quaternion(angle: -.pi / 2, axis: SIMD3(1, 0, 0)) : .identity
        scene.rootNode.orientation = rotation
        scene.rootNode.scale = SIMD3(repeating: units)
        for prim in stage.rootPrims {
            if let node = try node(prim, parentWorld: .identity, materials: USDMaterialReader(stage: stage, archive: archive), inheritedMaterial: nil) { scene.rootNode.addChild(node) }
        }
        return scene
    }

    private func node(_ prim: USDPrim, parentWorld: Matrix4x4, materials: USDMaterialReader, inheritedMaterial: MaterialDescriptor?) throws(SceneFormatError) -> Node? {
        if let active = prim.metadata["active"], try !USDRead.boolean(active) { return nil }
        if let instanceable = prim.metadata["instanceable"], try USDRead.boolean(instanceable) {
            throw .unsupported("USD instances at \(prim.path)")
        }
        if ["Material", "Shader", "NodeGraph"].contains(prim.typeName ?? "") {
            return nil
        }
        guard prim.typeName == nil || ["Xform", "Scope", "Mesh", "Camera", "DistantLight"].contains(prim.typeName ?? "") else {
            throw .unsupported("USD prim type \(prim.typeName ?? "") at \(prim.path)")
        }
        for property in prim.properties {
            if property.name.hasSuffix(".connect") { throw .unsupported("USD connections outside shading prims") }
            if property.name.hasPrefix("skel:") || property.name.hasPrefix("primvars:skel:") {
                throw .unsupported("USD skeletal deformation")
            }
            if property.name.hasPrefix("primvars:"), !["primvars:st", "primvars:st:indices"].contains(property.name) {
                throw .unsupported("USD primvar \(property.name)")
            }
            if property.name.hasPrefix("primvars:"), prim.typeName != "Mesh" {
                throw .unsupported("Inherited USD primvars")
            }
            if property.name.hasPrefix("xformOp"), !["Xform", "Mesh", "Camera", "DistantLight"].contains(prim.typeName ?? "") {
                throw .unsupported("USD transform on a non-Xformable prim")
            }
        }
        let boundMaterial = geometryOnly ? nil : try materials.binding(on: prim, inherited: inheritedMaterial)
        let result = Node(name: try USDRead.string(prim.metadata["displayName"] ?? .string(prim.name)))
        let transform = try USDTransform.matrix(prim)
        let local: Matrix4x4
        if transform.reset {
            guard let inverse = parentWorld.inverse else { throw .unsupported("USD reset under singular parent") }
            local = inverse * transform.matrix
        } else { local = transform.matrix }
        try USDTransform.assign(local, to: result)
        if let visibility = try USDRead.attribute(prim, "visibility", types: ["token"]) {
            let token = try USDRead.string(visibility)
            guard ["inherited", "invisible"].contains(token) else { throw USDRead.invalid("Invalid visibility") }
            result.isHidden = token == "invisible"
        }
        if let purpose = try USDRead.attribute(prim, "purpose", types: ["token"]), try USDRead.string(purpose) != "default" {
            throw .unsupported("USD non-default purpose")
        }
        if prim.typeName == "DistantLight", !geometryOnly { result.light = try USDDistantLight.decode(prim) }
        if prim.typeName == "Camera", !geometryOnly { result.camera = try USDCamera.decode(prim) }
        if prim.typeName == "Mesh" {
            let material = Material(boundMaterial ?? .default)
            if let value = try USDRead.attribute(prim, "doubleSided", types: ["bool"]) { material.isDoubleSided = try USDRead.boolean(value) }
            result.geometry = Geometry(mesh: try USDMesh.make(prim), materials: [material])
            for property in [material.diffuse, material.emission, material.metalness, material.roughness, material.normal, material.descriptor.ambientOcclusion] {
                if case .texture = property.contents, result.geometry?.mesh.stream(.textureCoordinate(0)) == nil {
                    throw USDRead.invalid("USD textured mesh requires primvars:st")
                }
            }
            result.geometry?.name = result.name
        }
        let world = parentWorld * local
        guard world.columnMajorElements.allSatisfy({ $0.isFinite }) else { throw USDRead.invalid("USD transform overflow") }
        for child in prim.children {
            if let node = try node(child, parentWorld: world, materials: materials, inheritedMaterial: boundMaterial) { result.addChild(node) }
        }
        return result
    }
}

enum USDRead {
    static func invalid(_ message: String) -> SceneFormatError { .malformed(message, offset: nil) }
    static func scalar(_ value: USDValue) throws(SceneFormatError) -> Float {
        guard case .number(let spelling) = value, let number = Float(spelling), number.isFinite else {
            throw invalid("Expected finite USD number representable as Float")
        }
        return number
    }
    static func string(_ value: USDValue) throws(SceneFormatError) -> String {
        guard case .string(let string) = value else { throw invalid("Expected USD token or string") }
        return string
    }
    static func boolean(_ value: USDValue) throws(SceneFormatError) -> Bool {
        guard case .boolean(let boolean) = value else { throw invalid("Expected USD boolean") }
        return boolean
    }
    static func array(_ value: USDValue) throws(SceneFormatError) -> [USDValue] {
        guard case .array(let values) = value else { throw invalid("Expected USD array") }
        return values
    }
    static func tuple(_ value: USDValue, count: Int) throws(SceneFormatError) -> [Float] {
        guard case .tuple(let values) = value, values.count == count else { throw invalid("Invalid USD tuple size") }
        var result: [Float] = []
        for value in values { result.append(try scalar(value)) }
        return result
    }
    static func integers(_ value: USDValue) throws(SceneFormatError) -> [Int] {
        var result: [Int] = []
        for value in try array(value) {
            guard case .number(let spelling) = value, let integer = Int(spelling) else {
                throw invalid("Expected representable USD integer")
            }
            result.append(integer)
        }
        return result
    }
    static func attribute(_ prim: USDPrim, _ name: String, types: [String]) throws(SceneFormatError) -> USDValue? {
        guard let property = prim[property: name] else { return nil }
        guard property.kind == .attribute, let type = property.typeName, types.contains(type) else {
            throw invalid("Invalid USD type for \(prim.path).\(name)")
        }
        guard property.value != .blocked else { throw .unsupported("Blocked USD attribute \(name)") }
        return property.value
    }
}
