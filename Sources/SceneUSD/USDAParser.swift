import SceneFormats

/// Parses the standalone static subset, without interpreting schema-specific attribute types.
struct USDAParser {
    private var lexer: USDALexer
    private var token: USDALexer.Token
    private static let compositionKeys: Set<String> = [
        "subLayers", "references", "payload", "payloads", "inherits", "specializes",
        "variantSets", "variants", "relocates", "clips"
    ]
    private static let listOperations: Set<String> = ["add", "append", "prepend", "delete", "reorder"]

    init(bytes: [UInt8]) throws(SceneFormatError) {
        var lexer = try USDALexer(bytes: bytes)
        token = try lexer.next()
        self.lexer = lexer
    }

    mutating func parse() throws(SceneFormatError) -> ([String: USDValue], [USDPrim]) {
        let metadata = try metadata(depth: 0)
        var prims: [USDPrim] = []
        var names: Set<String> = []
        while token.kind != .end {
            let prim = try prim(parent: "", depth: 0)
            guard names.insert(prim.name).inserted else { throw malformed("Duplicate root prim") }
            prims.append(prim)
        }
        return (metadata, prims)
    }

    private mutating func advance() throws(SceneFormatError) { token = try lexer.next() }

    private func malformed(_ message: String) -> SceneFormatError {
        .malformed(message, offset: token.offset)
    }

    private mutating func accept(_ character: UInt8) throws(SceneFormatError) -> Bool {
        guard token.kind == .punctuation(character) else { return false }
        try advance()
        return true
    }

    private mutating func require(_ character: UInt8) throws(SceneFormatError) {
        guard try accept(character) else {
            if token.kind == .end { throw .unexpectedEndOfData(offset: token.offset) }
            throw malformed("Expected '\(UnicodeScalar(character))'")
        }
    }

    private mutating func identifier(namespaced: Bool = false) throws(SceneFormatError) -> String {
        guard case .identifier(let name) = token.kind, USDALexer.isIdentifier(name, namespaced: namespaced) else {
            throw malformed("Expected USDA identifier")
        }
        try advance()
        return name
    }

    private mutating func typeName() throws(SceneFormatError) -> String {
        var name = try identifier()
        if try accept(91) { try require(93); name += "[]" }
        return name
    }

    private func checkDepth(_ depth: Int) throws(SceneFormatError) {
        // Swift debug builds use sizable recursive frames on small concurrency worker stacks.
        guard depth < 32 else { throw .unsupported("USDA nesting exceeds 32 levels") }
    }

    private mutating func prim(parent: String, depth: Int) throws(SceneFormatError) -> USDPrim {
        try checkDepth(depth)
        guard token.kind == .identifier("def") else {
            if case .identifier(let word) = token.kind, ["over", "class", "variantSet"].contains(word) {
                throw .unsupported("USDA \(word) composition")
            }
            throw malformed("Expected a prim definition")
        }
        try advance()
        let type: String?
        if case .identifier = token.kind { type = try identifier() } else { type = nil }
        guard case .string(let name) = token.kind else { throw malformed("Expected quoted prim name") }
        guard USDALexer.isIdentifier(name) else { throw .unsupported("USDA prim names must be ASCII identifiers") }
        try advance()
        let path = parent + "/" + name
        let metadata = try metadata(depth: depth + 1)
        try require(123)
        var children: [USDPrim] = []
        var properties: [USDProperty] = []
        var childNames: Set<String> = []
        var propertyNames: Set<String> = []
        while token.kind != .punctuation(125) {
            if token.kind == .end { throw .unexpectedEndOfData(offset: token.offset) }
            if case .identifier(let word) = token.kind, ["def", "over", "class", "variantSet"].contains(word) {
                let child = try prim(parent: path, depth: depth + 1)
                guard childNames.insert(child.name).inserted else { throw malformed("Duplicate child prim") }
                children.append(child)
            } else {
                let property = try property(depth: depth + 1)
                guard propertyNames.insert(property.name).inserted else { throw malformed("Duplicate property") }
                properties.append(property)
            }
        }
        try advance()
        _ = try accept(59)
        return USDPrim(name: name, path: path, typeName: type, metadata: metadata, properties: properties, children: children)
    }

    private mutating func property(depth: Int) throws(SceneFormatError) -> USDProperty {
        var custom = false
        var variability = USDProperty.Variability.varying
        var sawVariability = false
        while case .identifier(let word) = token.kind {
            if Self.listOperations.contains(word) { throw .unsupported("USDA list operations") }
            if word == "custom" {
                guard !custom else { throw malformed("Duplicate custom qualifier") }
                custom = true
            } else if word == "uniform" || word == "varying" {
                guard !sawVariability else { throw malformed("Duplicate variability qualifier") }
                sawVariability = true
                variability = word == "uniform" ? .uniform : .varying
            } else { break }
            try advance()
        }
        let relationship = token.kind == .identifier("rel")
        let type: String?
        if relationship { try advance(); type = nil } else { type = try typeName() }
        let name = try identifier(namespaced: true)
        if token.kind == .punctuation(46) {
            throw .unsupported("USDA property connections and time samples")
        }
        let value: USDValue?
        if try accept(61) { value = try self.value(depth: depth) } else { value = nil }
        if relationship, let value {
            let targets: [USDValue]
            if case .array(let array) = value { targets = array }
            else if value == .blocked { targets = [] }
            else { targets = [value] }
            guard targets.allSatisfy({ if case .path = $0 { return true }; return false }) else {
                throw malformed("Relationship targets must be paths")
            }
        }
        let metadata = try metadata(depth: depth)
        _ = try accept(59)
        return USDProperty(name: name, kind: relationship ? .relationship : .attribute,
                           typeName: type, isCustom: custom, variability: variability, value: value, metadata: metadata)
    }

    private mutating func metadata(depth: Int) throws(SceneFormatError) -> [String: USDValue] {
        guard try accept(40) else { return [:] }
        try checkDepth(depth)
        var result: [String: USDValue] = [:]
        while token.kind != .punctuation(41) {
            let name = try identifier()
            if Self.compositionKeys.contains(name) || Self.listOperations.contains(name) {
                throw .unsupported("USDA composition metadata: \(name)")
            }
            try require(61)
            let value = try value(depth: depth + 1)
            guard result.updateValue(value, forKey: name) == nil else { throw malformed("Duplicate metadata key") }
            _ = try accept(59)
        }
        try advance()
        return result
    }

    private mutating func value(depth: Int) throws(SceneFormatError) -> USDValue {
        try checkDepth(depth)
        switch token.kind {
        case .string(let string): try advance(); return .string(string)
        case .asset(let asset): try advance(); return .asset(asset)
        case .path(let path): try advance(); return .path(path)
        case .number(let number): try advance(); return .number(number)
        case .identifier("true"), .identifier("True"): try advance(); return .boolean(true)
        case .identifier("false"), .identifier("False"): try advance(); return .boolean(false)
        case .identifier("None"): try advance(); return .blocked
        case .punctuation(91): return .array(try sequence(closing: 93, depth: depth))
        case .punctuation(40): return .tuple(try sequence(closing: 41, depth: depth))
        case .punctuation(123):
            try advance()
            var result: [String: USDTypedValue] = [:]
            while token.kind != .punctuation(125) {
                let type = try typeName()
                let key: String
                if case .string(let string) = token.kind { key = string; try advance() }
                else { key = try identifier(namespaced: true) }
                try require(61)
                let entry = USDTypedValue(typeName: type, value: try value(depth: depth + 1))
                guard result.updateValue(entry, forKey: key) == nil else { throw malformed("Duplicate dictionary key") }
                _ = try accept(59)
            }
            try advance()
            return .dictionary(result)
        case .end: throw .unexpectedEndOfData(offset: token.offset)
        default: throw malformed("Expected USDA value")
        }
    }

    private mutating func sequence(closing: UInt8, depth: Int) throws(SceneFormatError) -> [USDValue] {
        try advance()
        var values: [USDValue] = []
        if try accept(closing) { return values }
        while true {
            values.append(try value(depth: depth + 1))
            if try accept(closing) { return values }
            try require(44)
            if try accept(closing) { return values }
        }
    }
}
