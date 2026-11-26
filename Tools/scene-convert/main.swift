// Converts between asset formats, e.g. a legacy .3dmf or .dae to .usdz or .glb. The codecs come with
// SceneFormats and SceneUSD; until then this reports usage.

let arguments = CommandLine.arguments.dropFirst()
guard arguments.count == 2 else {
    print("usage: scene-convert <input> <output>")
    exit(64)
}
print("scene-convert: no codecs are available yet")
exit(69)

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
