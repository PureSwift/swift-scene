import SceneCore
import SceneGraph
import SceneSDL
import SDL3Swift

// Shows a scene in a window for visual checks.
//
//   drag        orbit
//   wheel       zoom
//   W           wireframe
//   space       pause
//   R           reset the camera
//   Esc         quit
//
// Options:
//   --es               OpenGL ES 3.0 instead of OpenGL 3.3 Core
//   --frames <n>       quit after n frames
//   --snapshot <path>  draw one frame, save it as a bitmap, and quit

struct Options {
    var profile = SDLRenderBackend.Profile.core
    var frameLimit: Int?
    var snapshotPath: String?

    init(_ arguments: [String]) {
        var arguments = arguments.makeIterator()
        while let argument = arguments.next() {
            switch argument {
            case "--es": profile = .es
            case "--frames": frameLimit = arguments.next().flatMap { Int($0) }
            case "--snapshot": snapshotPath = arguments.next()
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

    let scene = makeScene()
    let renderer = SceneRenderer(backend: backend, scene: scene)
    let cameraNode = scene.rootNode.childNode(named: "camera")!
    var orbit = OrbitCamera(target: [0.6, 0.4, 0])
    orbit.apply(to: cameraNode)
    let clear = SIMD4<Float>(0.05, 0.06, 0.08, 1)

    if let path = options.snapshotPath {
        var commands = try backend.beginFrame(target: backend.target(clearColor: clear))
        renderer.encode(scene, target: commands.target, into: &commands)
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
            case .mouseButtonDown(_, _, .left, _, _, _):
                dragging = true
            case .mouseButtonUp(_, _, .left, _, _, _):
                dragging = false
            case let .mouseMotion(_, _, _, _, _, dx, dy) where dragging:
                orbit.drag(dx: dx, dy: dy)
                orbit.apply(to: cameraNode)
            case let .mouseWheel(_, _, _, y, isFlipped, _, _):
                orbit.zoom(isFlipped ? -y : y)
                orbit.apply(to: cameraNode)
            case let .keyDown(_, _, keycode, _, _):
                switch keycode {
                case .escape:
                    break running
                case .space:
                    scene.isPaused.toggle()
                case Keycode(character: "w"):
                    backend.renderer.isWireframe.toggle()
                case Keycode(character: "r"):
                    orbit = OrbitCamera(target: orbit.target)
                    orbit.apply(to: cameraNode)
                default:
                    break
                }
            default:
                break
            }
        }
        let now = clock.now
        renderer.update(by: now - last)
        last = now
        do {
            try renderer.render(target: backend.target(clearColor: clear))
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
