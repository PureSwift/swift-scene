// Regenerates the independent Apple reference; never run as part of the comparison test.
import AppKit
import SceneKit
import Metal
import simd
let directory = URL(fileURLWithPath: "Tests/SceneSDLTests/Fixtures", isDirectory: true)
let scene = try SCNScene(url: URL(fileURLWithPath: "Tests/SceneFormatsTests/Fixtures/reference.scn"))
scene.rootNode.enumerateChildNodes { node, _ in
    if node.light != nil { node.removeFromParentNode() }
    if let geometry = node.geometry {
        let material = SCNMaterial()
        material.lightingModel = .lambert
        material.diffuse.contents = node.name == "box" ? NSColor(srgbRed: 0.2, green: 0.5, blue: 0.85, alpha: 1) : NSColor(srgbRed: 1, green: 0.15, blue: 0.1, alpha: 1)
        geometry.materials = [material]
    }
}
let sun = SCNNode(); sun.light = SCNLight(); sun.light?.type = .directional; sun.light?.intensity = 800
sun.position = SCNVector3(2,3,4); sun.look(at: SCNVector3Zero); scene.rootNode.addChildNode(sun)
let fill = SCNNode(); fill.light = SCNLight(); fill.light?.type = .ambient; fill.light?.intensity = 200; scene.rootNode.addChildNode(fill)
let asset = directory.appendingPathComponent("comparison.scn")
guard scene.write(to: asset, options: nil, delegate: nil, progressHandler: nil) else { fatalError("write") }
let target = SIMD3<Float>(0.5,0.75,0.5)
let distance = simd_length(SIMD3<Float>(3,4.5,5) / 2) * 2.8
let yaw = Float.pi / 6, pitch = Float.pi / 9
let eye = target + SIMD3(cos(pitch)*sin(yaw),sin(pitch),cos(pitch)*cos(yaw)) * distance
let camera = SCNNode(); camera.camera = SCNCamera(); camera.camera?.fieldOfView = 60
camera.camera?.projectionDirection = .vertical; camera.camera?.zNear = 0.01; camera.camera?.zFar = 1000
camera.simdPosition = eye; camera.look(at: SCNVector3(target)); scene.rootNode.addChildNode(camera)
scene.background.contents = NSColor(srgbRed: pow(0.05,1/2.2), green: pow(0.06,1/2.2), blue: pow(0.08,1/2.2), alpha: 1)
let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
renderer.scene = scene; renderer.pointOfView = camera; renderer.autoenablesDefaultLighting = false
let image = renderer.snapshot(atTime: 0, with: CGSize(width:1280,height:720), antialiasingMode: .multisampling4X)
guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data:tiff), let png = bitmap.representation(using:.png,properties:[:]) else {fatalError("image")}
try png.write(to:directory.appendingPathComponent("apple-scenekit.png"))
print("Camera eye \(eye), target \(target), distance \(distance)")

// Small asymmetric textures make UV orientation and normal-map sampling observable.
func writeTexture(_ name: String, normal: Bool) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 128, bitsPerPixel: 32)!
    for y in 0..<32 {
        for x in 0..<32 {
            var color: [Int] = normal ? [180, 128, 244, 255]
                : (y < 16 ? (x < 16 ? [230, 70, 30, 255] : [30, 190, 70, 255])
                           : (x < 16 ? [40, 80, 220, 255] : [220, 190, 30, 255]))
            color.withUnsafeMutableBufferPointer { bitmap.setPixel($0.baseAddress!, atX: x, y: y) }
        }
    }
    try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
}
try writeTexture("quadrants.png", normal: false)
try writeTexture("tilted-normal.png", normal: true)
for variant in ["textured", "normal-mapped", "multi-material"] {
    let variantScene = try SCNScene(url: directory.appendingPathComponent("comparison.scn"))
    let box = variantScene.rootNode.childNode(withName: "box", recursively: true)!
    if variant == "multi-material" {
        box.geometry!.materials = (0..<6).map { index in
            let m = SCNMaterial(); m.lightingModel = .constant
            m.diffuse.contents = NSColor(srgbRed: CGFloat(index + 1) / 7, green: 0.25, blue: CGFloat(6 - index) / 7, alpha: 1)
            return m
        }
    } else {
        let m = SCNMaterial(); m.lightingModel = variant == "textured" ? .constant : .lambert
        if variant == "textured" { m.diffuse.contents = "quadrants.png" }
        else {
            m.diffuse.contents = NSColor(srgbRed: 0.2, green: 0.5, blue: 0.85, alpha: 1)
            m.normal.contents = "tilted-normal.png"
        }
        box.geometry!.materials = [m]
    }
    guard variantScene.write(to: directory.appendingPathComponent(variant + ".scn"), options: nil, delegate: nil, progressHandler: nil) else { fatalError("write") }
    let view = camera.clone(); variantScene.rootNode.addChildNode(view)
    variantScene.background.contents = scene.background.contents
    // Resolve external textures explicitly for the reference renderer after saving relative paths.
    for material in box.geometry!.materials {
        for property in [material.diffuse, material.normal] {
            if let path = property.contents as? String { property.contents = NSImage(contentsOf: directory.appendingPathComponent(path))! }
        }
    }
    renderer.scene = variantScene; renderer.pointOfView = view
    let snapshot = renderer.snapshot(atTime: 0, with: CGSize(width: 1280, height: 720), antialiasingMode: .multisampling4X)
    let bitmap = NSBitmapImageRep(data: snapshot.tiffRepresentation!)!
    try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(variant + "-apple.png"))
}
