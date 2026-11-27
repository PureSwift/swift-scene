import Foundation
import SceneCore
import SceneFormats
import SceneGraph
import SceneSDL
import SDL3Swift

// Shows a scene in a window for visual checks.
//
//   drag        orbit
//   wheel       zoom
//   F2          wireframe; N normals; H hierarchy; Tab fly; WASD/QE fly movement
//   space       pause
//   R           reset the camera
//   Esc         quit
//
// Usage: scene-viewer [options] [file]
//
// Supports .3dmf, .obj, .gltf, .glb, .dae, .scn and static USDA/USDZ, with dependency hot reload.
//
// Options:
//   --geometry-only    discard USD material bindings and shading prims
//   --inspector / --normals / --wireframe  enable diagnostic overlays
//   --es               OpenGL ES 3.0 instead of OpenGL 3.3 Core
//   --frames <n>       quit after n frames
//   --snapshot <path>  draw one frame, save it as a bitmap, and quit
//   --view <yaw> <pitch>  the camera's angles round and above the target, in degrees

struct Options {
    var profile = SDLRenderBackend.Profile.core
    var frameLimit: Int?
    var snapshotPath: String?
    var file: String?
    var view: (yaw: Float, pitch: Float)?
    var inspector = false
    var normals = false
    var wireframe = false
    var geometryOnly = false

    init(_ arguments: [String]) {
        var arguments = arguments.makeIterator()
        while let argument = arguments.next() {
            switch argument {
            case "--geometry-only": geometryOnly = true
            case "--inspector": inspector = true
            case "--normals": normals = true
            case "--wireframe": wireframe = true
            case "--es": profile = .es
            case "--frames": frameLimit = arguments.next().flatMap { Int($0) }
            case "--snapshot": snapshotPath = arguments.next()
            case "--view":
                if let yaw = arguments.next().flatMap(Float.init), let pitch = arguments.next().flatMap(Float.init) {
                    view = (yaw, pitch)
                }
            case let path where !path.hasPrefix("--"): file = path
            default: print("scene-viewer: ignoring \(argument)")
            }
        }
    }
}

/// A checkerboard, so texturing shows.
func checkerboard(size: Int = 256, squares: Int = 8) -> ImageBuffer {
    var pixels = [UInt8]()
    pixels.reserveCapacity(size * size * 4)
    for y in 0..<size {
        for x in 0..<size {
            let light = (x * squares / size + y * squares / size) % 2 == 0
            pixels.append(contentsOf: light ? [235, 235, 235, 255] : [40, 90, 200, 255])
        }
    }
    return ImageBuffer(width: size, height: size, format: .rgba8, pixels: pixels)
}

func makeScene() -> Scene {
    let checker = Material()
    checker.diffuse = .texture(.image(checkerboard()))
    checker.specular = .color(SIMD4(0.4, 0.4, 0.4, 1))
    checker.shininess = 0.3
    let box = Geometry.box()
    box.materials = [checker]

    let floorMaterial = Material(.lambert(diffuse: SIMD4(0.35, 0.35, 0.38, 1)))
    let gold = Material(.physicallyBased(baseColor: SIMD4(1, 0.78, 0.34, 1), metalness: 1, roughness: 0.35))

    return Scene {
        Node(name: "camera").camera(Camera(CameraDescriptor(zNear: 0.1, zFar: 200)))
        Node(name: "sun")
            .light(Light(LightDescriptor(kind: .directional, intensity: 900)))
            .positioned(at: [3, 5, 2])
            .looking(at: .zero)
        Node(name: "fill").light(Light(LightDescriptor(kind: .ambient, intensity: 200)))
        Node(name: "box", geometry: box)
            .positioned(at: [0, 0.5, 0])
            .running(.repeatForever(.rotate(by: 2 * .pi, around: [0, 1, 0], duration: .seconds(8))))
        Node(name: "torus", geometry: Geometry(.torus(ringRadius: 0.6, pipeRadius: 0.15), materials: [gold]))
            .positioned(at: [1.8, 0.5, 0])
            .running(.repeatForever(.rotate(by: 2 * .pi, around: [1, 0, 0], duration: .seconds(5))))
        Node(name: "floor", geometry: Geometry(.floor(width: 12, length: 12), materials: [floorMaterial]))
    }
}

/// A file's scene, with a camera, and lights when it has none.
func prepareScene(_ scene: Scene) -> Scene {
    var hasLight = false
    scene.rootNode.enumerateHierarchy { node, stop in
        if node.light != nil { hasLight = true; stop = true }
    }
    if !hasLight {
        scene.rootNode.addChild(Node(name: "sun")
            .light(Light(LightDescriptor(kind: .directional, intensity: 900)))
            .positioned(at: [2, 3, 4])
            .looking(at: .zero))
        scene.rootNode.addChild(Node(name: "fill").light(Light(LightDescriptor(kind: .ambient, intensity: 250))))
    }
    scene.rootNode.addChild(Node(name: "camera").camera(Camera(CameraDescriptor(zNear: 0.01, zFar: 1000))))
    return scene
}

/// An orbit framing the scene's geometry.
func framing(_ scene: Scene) -> OrbitCamera {
    let bounds = scene.rootNode.hierarchyBoundingBox
    guard !bounds.isEmpty else { return OrbitCamera() }
    let sphere = bounds.boundingSphere
    return OrbitCamera(target: sphere.center, yaw: 0, pitch: 0.2, distance: max(sphere.radius, 0.01) * 2.8)
}

func run() throws {
    let options = Options(Array(CommandLine.arguments.dropFirst()))
    try SDL.initialize(subSystems: [.video, .events])
    defer { SDL.quit() }

    let backend: SDLRenderBackend
    do {
        backend = try SDLRenderBackend(
            title: "scene-viewer",
            width: 1280,
            height: 720,
            profile: options.profile,
            isHidden: options.snapshotPath != nil
        )
    } catch {
        print("scene-viewer: \(error)")
        exit(1)
    }
    print("OpenGL: \(backend.renderer.version) — \(backend.renderer.renderer)")
    // Textures named by path, as OBJ materials name them.
    let asset = options.file.map { makeViewerAsset(url: URL(fileURLWithPath: $0), geometryOnly: options.geometryOnly) }
    backend.renderer.textureLoader = { source in
        if case .path(let path) = source, let asset, let bytes = asset.readTexture(path) {
            return TextureImageLoader.decode(bytes)
        }
        return TextureImageLoader.load(source)
    }
    backend.renderer.isWireframe = options.wireframe

    var scene = try asset.map { prepareScene(try $0.load()) } ?? makeScene()
    let renderer = SceneRenderer(backend: backend, scene: scene)
    // The viewer's own camera, which the orbit moves, rather than any a file brings.
    guard var cameraNode = scene.rootNode.children.last(where: { $0.name == "camera" }) else { return }
    renderer.pointOfView = cameraNode
    var initialOrbit = options.file == nil ? OrbitCamera(target: [0.6, 0.4, 0]) : framing(scene)
    var orbit = initialOrbit
    if let view = options.view {
        orbit.yaw = radians(degrees: view.yaw)
        orbit.pitch = radians(degrees: view.pitch)
    }
    orbit.apply(to: cameraNode)
    let clear = SIMD4<Float>(0.05, 0.06, 0.08, 1)

    var inspector = ViewerInspector(isVisible: options.inspector, showsNormals: options.normals)
    inspector.rebuild(scene)
    var fly = false
    var keys: Set<Keycode> = []
    var status = "READY"
    var watcher = AssetWatcher()
    if let asset { watcher.synchronize(asset) }
    print("Drag: orbit/look; wheel: zoom; Tab: fly; WASD/QE: move; F2: wireframe; N: normals; H: hierarchy; up/down: select; V: visibility; F: focus; R: reset; Space: pause")
    if let path = options.snapshotPath {
        var commands = try backend.beginFrame(target: backend.target(clearColor: clear))
        renderer.encode(scene, target: commands.target, into: &commands)
        inspector.encode(into: &commands, fly: fly, status: status)
        let image = try backend.snapshot(commands)
        guard writeBitmap(image, to: path) else {
            print("scene-viewer: couldn't write \(path)")
            exit(1)
        }
        print("Wrote \(image.width)×\(image.height) to \(path)")
        return
    }

    let clock = ContinuousClock()
    var last = clock.now
    var frames = 0
    var dragging = false
    running: while options.frameLimit.map({ frames < $0 }) ?? true {
        while let event = SDL.pollEvent() {
            switch event {
            case .quit, .window(_, .closeRequested):
                break running
            case .window(_, .focusLost):
                keys.removeAll()
                dragging = false
            case .mouseButtonDown(_, _, .left, _, _, _):
                dragging = true
            case .mouseButtonUp(_, _, .left, _, _, _):
                dragging = false
            case let .mouseMotion(_, _, _, _, _, dx, dy) where dragging:
                if fly { orbit.look(dx: dx, dy: dy) }
                else { orbit.drag(dx: dx, dy: dy) }
                orbit.apply(to: cameraNode)
            case let .mouseWheel(_, _, _, y, isFlipped, _, _):
                orbit.zoom(isFlipped ? -y : y)
                orbit.apply(to: cameraNode)
            case let .keyUp(_, _, keycode, _, _):
                keys.remove(keycode)
            case let .keyDown(_, _, keycode, _, _):
                guard keys.insert(keycode).inserted else { continue }
                switch keycode {
                case .escape:
                    break running
                case .space:
                    scene.isPaused.toggle()
                case .f2:
                    backend.renderer.isWireframe.toggle()
                case .tab: fly.toggle()
                case Keycode(character: "h"): inspector.isVisible.toggle()
                case Keycode(character: "n"): inspector.showsNormals.toggle()
                case .up: inspector.move(-1)
                case .down: inspector.move(1)
                case Keycode(character: "v"): inspector.selectedNode?.isHidden.toggle()
                case Keycode(character: "f"):
                    if let node = inspector.selectedNode {
                        let bounds = node.hierarchyBoundingBox.transformed(by: node.worldTransform)
                        if !bounds.isEmpty {
                            orbit.target = bounds.boundingSphere.center
                            orbit.distance = max(bounds.boundingSphere.radius * 2.8, 0.01)
                            orbit.apply(to: cameraNode)
                        }
                    }
                case Keycode(character: "r"):
                    orbit = initialOrbit
                    orbit.apply(to: cameraNode)
                default:
                    break
                }
            default:
                break
            }
        }
        let now = clock.now
        let duration = now - last
        let delta = min(Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18, 0.1)
        last = now
        if fly {
            func pressed(_ c: Unicode.Scalar) -> Float { keys.contains(Keycode(character: c)) ? 1 : 0 }
            orbit.move(forward: pressed("w") - pressed("s"), right: pressed("d") - pressed("a"),
                       up: pressed("e") - pressed("q"), seconds: Float(delta))
            orbit.apply(to: cameraNode)
        }
        if let asset, watcher.changed(asset, delta: delta) {
            do {
                let replacement = prepareScene(try asset.load())
                guard let camera = replacement.rootNode.children.last(where: { $0.name == "camera" }) else { continue }
                replacement.isPaused = scene.isPaused
                scene = replacement
                cameraNode = camera
                orbit.apply(to: cameraNode)
                renderer.scene = scene
                renderer.pointOfView = cameraNode
                initialOrbit = framing(scene)
                inspector.rebuild(scene)
                backend.renderer.invalidateTextures()
                watcher.synchronize(asset)
                status = "RELOADED"
                print("Reloaded \(asset.url.lastPathComponent)")
            } catch {
                status = "RELOAD FAILED - SEE CONSOLE"
                print("Reload failed; retaining scene: \(error)")
            }
        }
        renderer.update(by: .seconds(delta))
        do {
            var commands = try backend.beginFrame(target: backend.target(clearColor: clear))
            renderer.encode(scene, target: commands.target, into: &commands)
            inspector.encode(into: &commands, fly: fly, status: status)
            try backend.endFrame(commands)
        } catch .targetUnavailable {
            // Minimized: nothing to draw into.
            SDL.delay(nanoseconds: 16_000_000)
        }
        frames += 1
    }
}

extension Keycode {

    /// The key that types the character.
    init(character: Unicode.Scalar) {
        self.init(rawValue: character.value)
    }
}

do {
    try run()
} catch {
    print("scene-viewer: \(error)")
    exit(1)
}

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
