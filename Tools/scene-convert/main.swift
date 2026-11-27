import Foundation
import SceneFormats
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

let usage = """
usage: scene-convert [--force] [--geometry-only] [--aspect-ratio ratio] <input> <output>
Inputs: .3dmf, .3dm, .obj, .gltf, .glb, .dae, .scn
Outputs: .glb (embedded textures), .3dmf/.3dm (binary, limited color materials)
Exports the current visible pose. Animation, physics and backgrounds are not exported
by GLB; legacy materials are approximated as nonmetallic PBR surfaces.
Legacy lights map normalized strength to glTF intensity; distance falloff changes.
--geometry-only  Omit all cameras and lights.
--aspect-ratio   Positive width/height number for cameras without a fixed aspect.
--force          Replace an existing output file.
--               End options, allowing paths beginning with a dash.
"""

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data(("scene-convert: \(message)\n").utf8))
    exit(code)
}

var paths: [String] = []
var overwrite = false
var geometryOnly = false
var options = true
var cameraAspectRatio: Float?
var expectsAspectRatio = false
for argument in CommandLine.arguments.dropFirst() {
    if expectsAspectRatio {
        guard let aspect = Float(argument), aspect.isFinite, aspect > 0 else {
            fail("--aspect-ratio requires a positive finite number", code: 64)
        }
        cameraAspectRatio = aspect
        expectsAspectRatio = false
    }
    else if options && argument == "--aspect-ratio" { expectsAspectRatio = true }
    else if options && argument == "--" { options = false }
    else if options && ["--help", "-h"].contains(argument) { print(usage); exit(0) }
    else if options && argument == "--force" { overwrite = true }
    else if options && argument == "--geometry-only" { geometryOnly = true }
    else if options && argument.hasPrefix("-") { fail("Unknown option \(argument)\n\(usage)", code: 64) }
    else { paths.append(argument) }
}
guard paths.count == 2 && !expectsAspectRatio else { fail(usage, code: 64) }
do {
    try SceneAssetConverter.convert(from: URL(fileURLWithPath: paths[0]), to: URL(fileURLWithPath: paths[1]),
                                    overwrite: overwrite, geometryOnly: geometryOnly, cameraAspectRatio: cameraAspectRatio)
    print("Wrote \(paths[1]) (static scene export)")
} catch { fail(String(describing: error), code: 65) }
