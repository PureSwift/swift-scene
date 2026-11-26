# swift-scene
Swift 3D Engine

A pure-Swift 3D engine for Linux and Apple platforms: a SceneKit-style scene graph and a RealityKit-style ECS over
one data-oriented core, with asset codecs (3DMF, OBJ, glTF, Collada, SCN, USD) and an SDL3 host.

| Module | Contents |
| --- | --- |
| `SceneCore` | `Matrix4x4`, `Quaternion`, `Transform`, bounds, rays and frusta; the sparse-set `EntityStore`; `MeshBuffer`, `MaterialDescriptor`, light and camera descriptors; the `RenderBackend` and `FrameCommandBuffer` protocols |
| `SceneGraph` | `Scene`, `Node`, `Geometry` and the built-in primitives, `Material`, `Light`, `Camera`, `Action`, `Transaction`, `SceneRenderer`, `@NodeBuilder` |
| `SceneReality` | The ECS surface: `World`, `Entity`, `Component`, `System` *(planned)* |
| `SceneFormats` | Asset codecs: 3DMF (from Quesa), OBJ, glTF, Collada, SCN *(planned)* |
| `SceneUSD` | `.usda`, `.usdc` and `.usdz` *(planned)* |
| `ScenePhysics` | Rigid bodies and collision *(planned)* |
| `SceneSDL` | The SDL3 window host and OpenGL / Vulkan backend *(planned)* |

Conventions: right-handed, y up, cameras and lights look down -z, angles in radians (camera field of view and spot
angles in degrees, as SceneKit's). Matrices are column-major acting on column vectors; `Matrix4x4(quickDraw3D:)`
reads QuickDraw 3D's row-vector matrices.

```swift
import SceneGraph

let scene = Scene {
    Node(name: "camera").camera(Camera()).positioned(at: [0, 1.5, 4]).looking(at: .zero)
    Node(name: "box", geometry: .box())
        .running(.repeatForever(.rotate(by: 2 * .pi, around: [0, 1, 0], duration: .seconds(4))))
}
let renderer = SceneRenderer(backend: HeadlessRenderBackend(), scene: scene)
renderer.update(by: .milliseconds(16))
try renderer.render(target: RenderTargetDescriptor(width: 1280, height: 720))
```
