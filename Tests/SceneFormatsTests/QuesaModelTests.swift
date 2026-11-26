#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Testing
import SceneGraph
@testable import SceneFormats

/// Quesa's sample models, when a checkout of Quesa sits beside this package. They aren't copied here.
private let quesaModels: String? = {
    let root = String(#filePath).split(separator: "/").dropLast(3).joined(separator: "/")
    let path = "/" + root + "/../Quesa/SDK/Models"
    return access(path, R_OK) == 0 ? path : nil
}()

private func files(under directory: String, withExtension ext: String) -> [String] {
    guard let dir = opendir(directory) else { return [] }
    defer { closedir(dir) }
    var found: [String] = []
    while let entry = readdir(dir) {
        let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        guard name != ".", name != ".." else { continue }
        let path = directory + "/" + name
        if Int32(entry.pointee.d_type) == Int32(DT_DIR) {
            found += files(under: path, withExtension: ext)
        } else if name.lowercased().hasSuffix("." + ext) {
            found.append(path)
        }
    }
    return found.sorted()
}

func readFile(_ path: String) -> [UInt8]? {
    guard let file = fopen(path, "rb") else { return nil }
    defer { fclose(file) }
    var bytes: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        let count = fread(&buffer, 1, buffer.count, file)
        if count <= 0 { break }
        bytes += buffer[0..<count]
    }
    return bytes
}

@Suite(.enabled(if: quesaModels != nil, "Needs a Quesa checkout beside this package"))
struct QuesaModelTests {

    @Test func parsesEverySampleModel() throws {
        let paths = files(under: quesaModels!, withExtension: "3dmf")
        #expect(!paths.isEmpty)
        var failures: [String] = []
        for path in paths {
            guard let bytes = readFile(path) else { continue }
            do {
                let metafile = try Metafile3D(bytes)
                if metafile.objects.isEmpty { failures.append("\(path): no objects") }
            } catch {
                failures.append("\(path): \(error)")
            }
        }
        #expect(failures.isEmpty, Comment(rawValue: "\(failures.count) of \(paths.count) failed:\n" + failures.joined(separator: "\n")))
    }

    @Test func decodesEverySampleModel() throws {
        let paths = files(under: quesaModels!, withExtension: "3dmf")
        var failures: [String] = []
        var withGeometry = 0
        for path in paths {
            guard let bytes = readFile(path) else { continue }
            do {
                let scene = try ThreeDMFDecoder(isStrict: true).decodeScene(bytes)
                var hasGeometry = false
                scene.rootNode.enumerateHierarchy { node, stop in
                    if node.geometry != nil { hasGeometry = true; stop = true }
                }
                if hasGeometry { withGeometry += 1 }
            } catch {
                failures.append("\(path): \(error)")
            }
        }
        #expect(failures.isEmpty, Comment(rawValue: "\(failures.count) of \(paths.count) failed:\n" + failures.joined(separator: "\n")))
        // Every sample with a TriMesh, Triangle, Polygon or Box: 31 at Quesa's a7dccbff. The curved surfaces come later.
        #expect(withGeometry >= 31)
        print("Decoded geometry from \(withGeometry) of \(paths.count) sample models")
    }
}
