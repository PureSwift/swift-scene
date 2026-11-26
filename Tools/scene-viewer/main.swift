import SceneCore
import SceneGraph

// Shows a scene for visual checks. Until SceneSDL's OpenGL backend lands this renders a rotating box with the
// headless backend and prints what each frame would draw.

let scene = Scene {
    Node(name: "camera")
        .camera(Camera())
        .positioned(at: [0, 1.5, 4])
        .looking(at: .zero)
    Node(name: "light")
        .light(Light(kind: .directional))
        .looking(at: [-1, -2, -1])
    Node(name: "box", geometry: .box())
        .running(.repeatForever(.rotate(by: 2 * .pi, around: [0, 1, 0], duration: .seconds(4))))
}

let renderer = SceneRenderer(backend: HeadlessRenderBackend(), scene: scene)
let target = RenderTargetDescriptor(width: 1280, height: 720)
let frame = Duration.milliseconds(500)

for index in 0..<8 {
    renderer.update(by: frame)
    try renderer.render(target: target)
    let draws = renderer.backend.lastFrame?.drawCalls ?? []
    let box = scene.rootNode.childNode(named: "box")!
    print("frame \(index): \(draws.count) draws, box yaw \(degrees(radians: box.orientation.angle))°")
}
