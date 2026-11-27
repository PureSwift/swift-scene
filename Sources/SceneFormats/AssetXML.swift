import Foundation

/// Small bounded XML DOM for asset documents. External entities and DTDs are not evaluated.
final class AssetXML {
    let name: String
    let attributes: [String: String]
    var children: [AssetXML] = []
    var text = ""

    init(name: String, attributes: [String: String] = [:]) {
        self.name = name.split(separator: ":").last.map(String.init) ?? name
        self.attributes = attributes
    }

    subscript(_ name: String) -> AssetXML? { children.first { $0.name == name } }
    func all(_ name: String) -> [AssetXML] { children.filter { $0.name == name } }
    var words: [Substring] { text.split(whereSeparator: \.isWhitespace) }

    func floats() throws(SceneFormatError) -> [Float] {
        var values: [Float] = []
        for token in words {
            guard let value = Float(token), value.isFinite else { throw .malformed("Invalid XML float", offset: nil) }
            values.append(value)
        }
        return values
    }

    func integers() throws(SceneFormatError) -> [Int] {
        var values: [Int] = []
        for token in words {
            guard let value = Int(token), value >= 0 else { throw .malformed("Invalid XML index", offset: nil) }
            values.append(value)
        }
        return values
    }

    static func parse(_ bytes: [UInt8]) throws(SceneFormatError) -> AssetXML {
        guard var text = String(bytes: bytes, encoding: .utf8) else { throw .invalidHeader("XML must be UTF-8") }
        if text.first == "\u{feff}" { text.removeFirst() }
        var input = text[...]
        var stack: [AssetXML] = []
        var root: AssetXML?
        var count = 0
        func skipSpace() { while input.first?.isWhitespace == true { input.removeFirst() } }
        func consume(_ prefix: String) -> Bool {
            guard input.hasPrefix(prefix) else { return false }
            input = input.dropFirst(prefix.count)
            return true
        }
        func through(_ delimiter: String) throws(SceneFormatError) -> String {
            guard let range = input.range(of: delimiter) else { throw .malformed("Unterminated XML token", offset: nil) }
            let value = String(input[..<range.lowerBound])
            input = input[range.upperBound...]
            return value
        }
        func name() throws(SceneFormatError) -> String {
            let token = input.prefix { !$0.isWhitespace && !["/", ">", "=", "?", "<"].contains($0) }
            guard !token.isEmpty else { throw .malformed("Missing XML name", offset: nil) }
            input = input.dropFirst(token.count)
            return String(token)
        }
        while !input.isEmpty {
            if consume("<!--") { _ = try through("-->"); continue }
            if consume("<?") { _ = try through("?>"); continue }
            if consume("<![CDATA[") {
                let value = try through("]]>")
                guard let node = stack.last else { throw .malformed("CDATA outside root", offset: nil) }
                node.text += value
                continue
            }
            if consume("</") {
                let closing = try name().split(separator: ":").last.map(String.init)
                skipSpace()
                guard consume(">"), stack.last?.name == closing else { throw .malformed("Mismatched XML element", offset: nil) }
                stack.removeLast()
                continue
            }
            if consume("<") {
                guard !input.hasPrefix("!") else { throw .unsupported("XML DTD declarations are not supported") }
                let elementName = try name()
                var attributes: [String: String] = [:]
                var closed = false
                while true {
                    skipSpace()
                    if consume("/>") { closed = true; break }
                    if consume(">") { break }
                    let key = try name()
                    skipSpace()
                    guard consume("=") else { throw .malformed("Missing XML attribute value", offset: nil) }
                    skipSpace()
                    guard let quote = input.first, quote == "\"" || quote == "'" else {
                        throw .malformed("Unquoted XML attribute", offset: nil)
                    }
                    input.removeFirst()
                    guard attributes[key] == nil else { throw .malformed("Duplicate XML attribute", offset: nil) }
                    attributes[key] = try unescape(through(String(quote)))
                }
                count += 1
                guard count <= 1_000_000, stack.count < 256 else { throw .unsupported("XML document exceeds limits") }
                let node = AssetXML(name: elementName, attributes: attributes)
                if let parent = stack.last { parent.children.append(node) }
                else {
                    guard root == nil else { throw .malformed("Multiple XML roots", offset: nil) }
                    root = node
                }
                if !closed { stack.append(node) }
            } else {
                let value = input.prefix { $0 != "<" }
                input = input.dropFirst(value.count)
                if let node = stack.last { node.text += try unescape(String(value)) }
                else if !value.allSatisfy(\.isWhitespace) { throw .malformed("Text outside XML root", offset: nil) }
            }
        }
        guard stack.isEmpty, let root else { throw .malformed("Incomplete XML document", offset: nil) }
        return root
    }

    private static func unescape(_ text: String) throws(SceneFormatError) -> String {
        var input = text[...], result = ""
        while let ampersand = input.firstIndex(of: "&") {
            result += input[..<ampersand]
            input = input[input.index(after: ampersand)...]
            guard let end = input.firstIndex(of: ";") else { throw .malformed("Unterminated XML entity", offset: nil) }
            let entity = input[..<end]
            input = input[input.index(after: end)...]
            switch entity {
            case "amp": result += "&"
            case "lt": result += "<"
            case "gt": result += ">"
            case "quot": result += "\""
            case "apos": result += "'"
            default:
                let value: UInt32?
                if entity.hasPrefix("#x") { value = UInt32(entity.dropFirst(2), radix: 16) }
                else if entity.hasPrefix("#") { value = UInt32(entity.dropFirst()) }
                else { value = nil }
                guard let value, let scalar = UnicodeScalar(value), value > 0 else {
                    throw .malformed("Unknown XML entity", offset: nil)
                }
                result.unicodeScalars.append(scalar)
            }
        }
        result += input
        return result
    }
}
