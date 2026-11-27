import Foundation
import Testing
import SceneFormats
@testable import SceneUSD

@Suite struct USDAParserTests {
    private func parse(_ text: String) throws -> USDStage {
        try USDStage(usda: Array(("#usda 1.0\n" + text).utf8))
    }

    @Test func readsMeshFixtureAndTraversesHierarchy() throws {
        let url = try #require(Bundle.module.url(forResource: "triangle", withExtension: "usda", subdirectory: "Fixtures"))
        let stage = try USDStage(usda: Array(Data(contentsOf: url)))
        #expect(stage.defaultPrim?.path == "/World")
        #expect(stage.metadata["upAxis"] == .string("Y"))
        #expect(stage.traverse().map(\.path) == ["/World", "/World/Triangle", "/World/Material"])
        let mesh = try #require(stage.prim(at: "/World/Triangle"))
        #expect(mesh.typeName == "Mesh")
        #expect(mesh[property: "points"]?.typeName == "point3f[]")
        #expect(mesh[property: "faceVertexIndices"]?.value == .array([.number("0"), .number("1"), .number("2")]))
        #expect(mesh[property: "normals"]?.metadata["interpolation"] == .string("constant"))
        #expect(mesh[property: "material:binding"]?.kind == .relationship)
        #expect(mesh[property: "material:binding"]?.value == .path("/World/Material"))
        #expect(mesh[property: "preview"]?.value == .asset("textures/pixel.png"))
        #expect(mesh[property: "label"]?.value == .string("Triangle — café"))
        #expect(mesh[property: "optionalValue"]?.value == nil)
        #expect(mesh[property: "blockedValue"]?.value == .blocked)
        #expect(mesh[property: "label"]?.isCustom == true)
        #expect(stage.defaultPrim?[property: "xformOpOrder"]?.variability == .uniform)
        guard case .dictionary(let dictionary) = stage.metadata["customLayerData"] else {
            Issue.record("Expected typed dictionary"); return
        }
        #expect(dictionary["identifier"]?.typeName == "uint64")
        #expect(dictionary["identifier"]?.value == .number("18446744073709551615"))
        for path in ["World", "/", "/World/", "/World//Triangle", "/World/Triangle.points", "/Missing"] {
            #expect(stage.prim(at: path) == nil)
        }
    }

    @Test func opensPackagedUSDAAndRejectsCrate() throws {
        let url = try #require(Bundle.module.url(forResource: "reference", withExtension: "usdz", subdirectory: "Fixtures"))
        let stage = try USDStage(archive: USDZArchive(Array(Data(contentsOf: url))))
        #expect(stage.defaultPrim?.name == "World")
        let crate = try USDZArchive(entries: [.init(path: "root.usdc", data: Array("PXR-USDC".utf8))])
        #expect(throws: SceneFormatError.unsupported("USDC Crate layers")) { try USDStage(archive: crate) }
        let empty = try USDZArchive(entries: [])
        #expect(throws: SceneFormatError.self) { try USDStage(archive: empty) }
    }

    @Test func scalarTupleArrayAndStringSyntax() throws {
        let stage = try parse(#"""
        # Comments may precede declarations.
        def "Values" {
            bool yes = True; bool no = false
            double[] numbers = [-1, +2, .5, 6., 1e-3, -inf, inf, nan,]
            matrix2d matrix = ((1, 0), (0, 1))
            string escaped = "line\n\t\"quoted\"\\end"
            string single = 'single \'quote'
            string multiline = '''first
        second # inside a string'''
            token[] empty = []
            rel targets = [</A>, <../B>]
            rel blocked = None
            customDataType uninterpreted = (1, 2)
        }
        """#)
        let prim = try #require(stage.prim(at: "/Values"))
        #expect(prim.typeName == nil)
        #expect(prim[property: "yes"]?.value == .boolean(true))
        #expect(prim[property: "no"]?.value == .boolean(false))
        #expect(prim[property: "escaped"]?.value == .string("line\n\t\"quoted\"\\end"))
        #expect(prim[property: "single"]?.value == .string("single 'quote"))
        #expect(prim[property: "multiline"]?.value == .string("first\nsecond # inside a string"))
        #expect(prim[property: "empty"]?.value == .array([]))
        #expect(prim[property: "numbers"]?.value == .array(["-1", "+2", ".5", "6.", "1e-3", "-inf", "inf", "nan"].map(USDValue.number)))
        #expect(prim[property: "matrix"]?.value == .tuple([
            .tuple([.number("1"), .number("0")]), .tuple([.number("0"), .number("1")])]))
        #expect(prim[property: "targets"]?.value == .array([.path("/A"), .path("../B")]))
    }

    @Test func preservesShadingConnectionsWithoutEvaluatingThem() throws {
        let stage = try parse("""
        def Material "M" {
            token outputs:surface.connect = </M/S.outputs:surface>
            def Shader "S" {
                color3f inputs:diffuseColor.connect = [</Texture.outputs:rgb>]
                float inputs:roughness.connect = None
            }
        }
        """)
        #expect(stage.prim(at: "/M")?[property: "outputs:surface.connect"]?.value == .path("/M/S.outputs:surface"))
        #expect(stage.prim(at: "/M/S")?[property: "inputs:diffuseColor.connect"]?.value == .array([.path("/Texture.outputs:rgb")]))
        #expect(stage.prim(at: "/M/S")?[property: "inputs:roughness.connect"]?.value == .blocked)
        for text in [
            "def Shader \"S\" { float inputs:x.connect = 1 }",
            "def Shader \"S\" { float inputs:x.connect }",
            "def Shader \"S\" { float inputs:x.connect = [</A.x>, 1] }",
            "def Shader \"S\" { rel outputs:x.connect = </A.x> }"
        ] {
            #expect(throws: SceneFormatError.self) { try parse(text) }
        }
        let nonShader = try parse("def Xform \"X\" { float inputs:x.connect = </A.x> }")
        #expect(throws: SceneFormatError.self) { try USDSceneDecoder(geometryOnly: true).decodeScene(nonShader) }
    }

    @Test func rejectsCompositionAndAnimationInsteadOfDroppingThem() throws {
        for text in [
            "(subLayers = [@other.usda@])", "over \"World\" {}", "class \"Base\" {}",
            "def \"World\" (references = @other.usda@) {}",
            "def \"World\" (prepend references = @other.usda@) {}",
            "def \"World\" (variants = { string model = \"a\" }) {}",
            "def \"World\" { variantSet \"model\" = {} }",
            "def \"World\" { float x.timeSamples = { 0: 1 } }",
            "def \"World\" { float x.connect = </Other.x> }",
            "def \"World\" { prepend rel target = </Other> }"
        ] {
            do { _ = try parse(text); Issue.record("Accepted unsupported syntax: \(text)") }
            catch let error as SceneFormatError {
                guard case .unsupported = error else { Issue.record("Expected unsupported, got \(error)"); continue }
            }
        }
    }

    @Test func rejectsMalformedAndDuplicateDeclarations() throws {
        for text in [
            "def \"A\" {} def \"A\" {}", "def \"A\" { def \"B\" {} def \"B\" {} }",
            "def \"A\" { float x = 1 float x = 2 }", "(upAxis = \"Y\" upAxis = \"Z\")",
            "(customLayerData = { int x = 1 int x = 2 })",
            "def \"A\" { float[] x = [1 2] }", "def \"A\" { float x = 1e+ }",
            "def \"A\" { float x = 1e999 }", "def \"A\" { string x = \"unterminated }",
            "def \"A\" { rel target = 3 }", "def \"A\" { rel targets = [</A>, 2] }",
            "def \"A\" { float x = @unterminated }", "def \"A\" { float x = <unterminated }",
            "def \"A\" { uniform varying float x }", "def \"A\" { custom custom float x }",
            "def \"A\" {} garbage", "def \"A\" { float a::b = 1 }"
        ] {
            #expect(throws: SceneFormatError.self) { try parse(text) }
        }
        for bytes in [Array("#usda 2.0\n".utf8), Array("#usda 1.0\n".utf8) + [255], []] {
            #expect(throws: SceneFormatError.self) { try USDStage(usda: bytes) }
        }
    }

    @Test func truncationAndNestingAreBounded() throws {
        let bytes = Array("#usda 1.0\ndef \"A\" { float[] x = [1, 2, 3] }".utf8)
        // An empty layer is valid; all prefixes after the first declaration begins must fail.
        for end in 12..<bytes.count {
            #expect(throws: SceneFormatError.self) { try USDStage(usda: Array(bytes.prefix(end))) }
        }
        let nested = String(repeating: "def \"A\" {", count: 140) + String(repeating: "}", count: 140)
        #expect(throws: SceneFormatError.self) { try parse(nested) }
        let arrays = "def \"A\" { float[] x = " + String(repeating: "[", count: 140)
            + "1" + String(repeating: "]", count: 140) + "}"
        #expect(throws: SceneFormatError.self) { try parse(arrays) }
        let accepted = String(repeating: "def \"A\" {", count: 20) + String(repeating: "}", count: 20)
        #expect(try parse(accepted).traverse().count == 20)
        let dictionaries = "(customLayerData = " + String(repeating: "{ dictionary x = ", count: 140)
            + "{}" + String(repeating: "}", count: 140) + ")"
        #expect(throws: SceneFormatError.self) { try parse(dictionaries) }
    }

    @Test func everyByteMutationTerminatesSafely() throws {
        let bytes = Array("#usda 1.0\ndef \"A\" { float[] x = [1, 2, 3] string label = \"é\" }".utf8)
        for index in bytes.indices {
            for replacement: UInt8 in [0, 10, 34, 64, 91, 123, 255] {
                var changed = bytes
                changed[index] = replacement
                do { _ = try USDStage(usda: changed) } catch { /* Valid mutations may also succeed. */ }
            }
        }
    }
}
