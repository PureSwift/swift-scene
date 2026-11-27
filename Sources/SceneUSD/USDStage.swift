import SceneFormats

/// Authored USDA values. Numeric spelling is retained so 64-bit integers do not lose precision.
/// This syntax model does not apply schema defaults or validate schema-specific value types.
public indirect enum USDValue: Hashable, Sendable {
    case boolean(Bool)
    case number(String)
    case string(String)
    case asset(String)
    case path(String)
    case array([USDValue])
    case tuple([USDValue])
    case dictionary([String: USDTypedValue])
    /// The USDA `None` value block, distinct from an absent authored value.
    case blocked
}

/// A dictionary entry keeps its declared type, including array suffixes.
public struct USDTypedValue: Hashable, Sendable {
    public let typeName: String
    public let value: USDValue
}

public struct USDProperty: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case attribute, relationship }
    public enum Variability: Hashable, Sendable { case varying, uniform }

    public let name: String
    public let kind: Kind
    /// Nil for relationships.
    public let typeName: String?
    public let isCustom: Bool
    public let variability: Variability
    public let value: USDValue?
    public let metadata: [String: USDValue]
}

public struct USDPrim: Hashable, Sendable {
    public let name: String
    public let path: String
    /// Nil for a typeless definition.
    public let typeName: String?
    public let metadata: [String: USDValue]
    public let properties: [USDProperty]
    public let children: [USDPrim]

    public subscript(property name: String) -> USDProperty? {
        properties.first { $0.name == name }
    }
}

/// A standalone, static USDA stage containing definitions from one layer.
/// Composition arcs, overrides/classes, variants, connections and time samples are rejected.
/// Assets and relationship paths are retained as authored; no files are opened or resolved.
public struct USDStage: Hashable, Sendable {
    public let metadata: [String: USDValue]
    public let rootPrims: [USDPrim]

    public init(usda bytes: [UInt8]) throws(SceneFormatError) {
        var parser = try USDAParser(bytes: bytes)
        (metadata, rootPrims) = try parser.parse()
    }

    /// Opens the package's first layer when it contains USDA text. Crate layers are unsupported.
    public init(archive: USDZArchive) throws(SceneFormatError) {
        guard let layer = archive.defaultLayer else {
            throw .malformed("USDZ has no default USD layer", offset: nil)
        }
        if layer.data.prefix(8).elementsEqual(Array("PXR-USDC".utf8)) {
            throw .unsupported("USDC Crate layers")
        }
        try self.init(usda: Array(layer.data))
    }

    public var defaultPrim: USDPrim? {
        guard case .string(let name) = metadata["defaultPrim"] else { return nil }
        return rootPrims.first { $0.name == name }
    }

    /// Looks up an absolute prim path. Property paths and relative paths are not accepted.
    public func prim(at path: String) -> USDPrim? {
        guard path.first == "/" else { return nil }
        let components = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        var siblings = rootPrims
        var result: USDPrim?
        for component in components {
            guard !component.isEmpty, let prim = siblings.first(where: { $0.name == component }) else { return nil }
            result = prim
            siblings = prim.children
        }
        return result
    }

    /// Depth-first authored order, including inactive definitions. This is not a composed UsdPrimRange.
    public func traverse() -> [USDPrim] {
        var result: [USDPrim] = []
        var pending = Array(rootPrims.reversed())
        while let prim = pending.popLast() {
            result.append(prim)
            pending.append(contentsOf: prim.children.reversed())
        }
        return result
    }
}
