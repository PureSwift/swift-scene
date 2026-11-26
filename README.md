# swift-scene
Swift 3D Engine

A Swift 3D engine for Linux first, and Apple platforms: a SceneKit-style scene graph and a RealityKit-style ECS over
one data-oriented core, with asset codecs (3DMF, OBJ, glTF, Collada, SCN, USD), Box3D physics and an SDL3 host.

## Architecture

```
                 scene-viewer     scene-convert
                      |                 |
        +-------------+--------+--------+---------+
        |             |        |                  |
    SceneSDL     SceneFormats  SceneUSD      ScenePhysics
   (SDL3, GL)     (3DMF, …)   (SwiftUsd)       (Box3D)
        |             |        |                  |
        |         SceneGraph  SceneReality        |
        |             |        |                  |
        +-------------+--------+------------------+
                           SceneCore
```

`SceneCore` is the shared foundation: math, the `EntityStore` both APIs keep their state in, mesh and material
descriptors every renderer and codec reads, and the render backend protocols. `SceneGraph` (nodes, as SceneKit) and
`SceneReality` (entities and systems, as RealityKit) are two surfaces over it, so they share assets and can render
side by side. Codecs read files into scenes, physics moves `EntityStore` transforms, and backends draw
`SceneCore` frames.

| Module | Contents |
| --- | --- |
| `SceneCore` | `Matrix4x4`, `Quaternion`, `Transform`, bounds, rays and frusta; polygon `Triangulation` with holes; the sparse-set `EntityStore`; `MeshBuffer`, `MaterialDescriptor`, light and camera descriptors; the `RenderBackend` and `FrameCommandBuffer` protocols |
| `SceneGraph` | `Scene`, `Node`, `Geometry` and the built-in primitives, `QuadricSurface` (QuickDraw 3D's ellipsoids, cones, cylinders, disks and tori), `NURBSPatch` and `NURBSCurve`, `Material`, `Light`, `Camera`, `Action`, `Transaction`, `SceneRenderer`, `@NodeBuilder` |
| `SceneReality` | The ECS surface: `World`, `Entity`, `Component`, `System` *(planned)* |
| `SceneFormats` | `ThreeDMFDecoder`: QuickDraw 3D metafiles, binary (either byte order) and text, ported from Quesa; `WavefrontOBJDecoder` and `MTLDecoder`: Wavefront OBJ and material libraries; glTF, Collada and SCN *(planned)* |
| `SceneUSD` | USD stages, `.usda`, `.usdc` and `.usdz` through [apple/SwiftUsd](https://github.com/apple/SwiftUsd)'s OpenUSD, on Apple platforms *(planned)* |
| `ScenePhysics` | `PhysicsWorld`, `PhysicsBody`, `PhysicsShape` (spheres, capsules, boxes, convex hulls, triangle meshes) and joints (hinge, slider, ball and socket, distance, weld) over [Box3D](https://github.com/erincatto/box3d); `PhysicsBodyComponent` keeps `EntityStore` transforms in step, and `Scene.physicsWorld` and `Node.makePhysicsBody` give SceneGraph SceneKit's physics; on Linux for now |
| `SceneSDL` | `SDLRenderBackend`: an SDL3 window with an OpenGL 3.3 Core / ES 3.0 context, and `OpenGLRenderer`, which draws `SceneCore` frames in any current GL context |

## Building

Swift 6 on Linux (developed on Debian 13) or macOS. Two system libraries:

- **SDL3** for `SceneSDL` and `scene-viewer`: `apt install libsdl3-dev`, or `brew install sdl3`.
- **Box3D** for `ScenePhysics`, built with CMake and found by pkg-config. Without root, install it in your home:

  ```sh
  git clone https://github.com/erincatto/box3d.git
  cmake -S box3d -B box3d/build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$HOME/.local \
    -DBOX3D_SAMPLES=OFF -DBOX3D_UNIT_TESTS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON
  cmake --build box3d/build -j && cmake --install box3d/build
  export PKG_CONFIG_PATH=$HOME/.local/lib/pkgconfig
  ```

  On Apple platforms `ScenePhysics` doesn't link Box3D yet, and builds empty.

```sh
swift build
swift test
```

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

`scene-viewer [file.3dmf | file.obj]` opens a window on a file, or on a demo scene without one: drag to orbit, scroll to zoom, W for wireframe, space to pause,
R to reset the camera. `--snapshot <path.bmp>` draws one frame to a file, `--frames <n>` quits after n frames,
and `--es` asks for OpenGL ES 3.0.

It needs SDL3: `brew install sdl3` on macOS, `apt install libsdl3-dev` on Debian and Ubuntu.

```sh
swift run scene-viewer
```

## Acknowledgments

The 3DMF reader is ported from [Quesa](https://github.com/jwwalker/quesa), © 1999–2021 Quesa Developers, under the
BSD 3-Clause License in `LICENSE-Quesa`.
