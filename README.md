# swift-scene
Swift 3D Engine

A pure-Swift 3D engine for Linux and Apple platforms: a SceneKit-style scene graph and a RealityKit-style ECS over
one data-oriented core, with asset codecs (3DMF, OBJ, glTF, Collada, SCN, USD) and an SDL3 host.

| Module | Contents |
| --- | --- |
| `SceneCore` | `Matrix4x4`, `Quaternion`, `Transform`, bounds, rays and frusta; the sparse-set `EntityStore`; `MeshBuffer`, `MaterialDescriptor`, light and camera descriptors; the `RenderBackend` and `FrameCommandBuffer` protocols |
| `SceneGraph` | `Scene`, `Node`, `Geometry` and the built-in primitives, `Material`, `Light`, `Camera`, `Action`, `Transaction`, `SceneRenderer`, `@NodeBuilder` |
| `SceneReality` | The ECS surface: `World`, `Entity`, `Component`, `System` *(planned)* |
| `SceneFormats` | `ThreeDMFDecoder`: QuickDraw 3D metafiles, binary (either byte order) and text, ported from Quesa; OBJ, glTF, Collada and SCN *(planned)* |
| `SceneUSD` | `.usda`, `.usdc` and `.usdz` *(planned)* |
| `ScenePhysics` | Rigid bodies and collision *(planned)* |
| `SceneSDL` | `SDLRenderBackend`: an SDL3 window with an OpenGL 3.3 Core / ES 3.0 context, and `OpenGLRenderer`, which draws `SceneCore` frames in any current GL context |

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

## Viewer

`scene-viewer [file.3dmf]` opens a window on a file, or on a demo scene without one: drag to orbit, scroll to zoom, W for wireframe, space to pause,
R to reset the camera. `--snapshot <path.bmp>` draws one frame to a file, `--frames <n>` quits after n frames,
and `--es` asks for OpenGL ES 3.0.

It needs SDL3: `brew install sdl3` on macOS, `apt install libsdl3-dev` on Debian and Ubuntu.

```sh
swift run scene-viewer
```

## Acknowledgments

The 3DMF reader is ported from [Quesa](https://github.com/jwwalker/quesa), © 1999–2021 Quesa Developers, under the
BSD 3-Clause License in `LICENSE-Quesa`.
