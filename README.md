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
| `SceneFormats` | `ThreeDMFDecoder`: QuickDraw 3D metafiles, binary (either byte order, parsed with [apple/swift-binary-parsing](https://github.com/apple/swift-binary-parsing)) and text, ported from Quesa — geometry, attributes, textures, lights, cameras, view hints and styles; `WavefrontOBJDecoder` and `MTLDecoder`: Wavefront OBJ and material libraries; `PNGDecoder` (over [PureSwift/swift-png](https://github.com/PureSwift/swift-png)) and `TextureImageLoader` for PNG/JPEG textures via [PureSwift/swift-jpeg](https://github.com/PureSwift/swift-jpeg); `GLTFDecoder` for glTF/GLB with animation and CPU skinning, `ColladaDecoder`, `SCNArchiveDecoder`, and `SceneAssetFile` for local resources and dependency tracking |
| `SceneUSD` | USD stages, `.usda`, `.usdc` and `.usdz` through [apple/SwiftUsd](https://github.com/apple/SwiftUsd)'s OpenUSD, on Apple platforms *(planned)* |
| `ScenePhysics` | `PhysicsWorld`, `PhysicsBody`, `PhysicsShape` (spheres, capsules, boxes, convex hulls, triangle meshes) and joints (hinge, slider, ball and socket, distance, weld) over [Box3D](https://github.com/erincatto/box3d); `PhysicsBodyComponent` keeps `EntityStore` transforms in step, and `Scene.physicsWorld` and `Node.makePhysicsBody` give SceneGraph SceneKit's physics; on Linux for now |
| `SceneSDL` | `SDLRenderBackend`: an SDL3 window with an OpenGL 3.3 Core / ES 3.0 context, and `OpenGLRenderer`, which draws `SceneCore` frames in any current GL context |

## Building

Swift 6 on Linux (developed on Debian 13) or macOS 15 and later. System libraries:

- **SDL3** for `SceneSDL` and `scene-viewer`: `apt install libsdl3-dev`, or `brew install sdl3`.
- **zlib** for swift-png's default system-zlib trait: `apt install zlib1g-dev`.
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

`scene-viewer [file]` opens `.3dmf`, `.obj`, `.gltf`, `.glb`, `.dae`, or `.scn`, or a rotating textured demo without a file.
Source assets, external buffers, material libraries, and texture files are checked for changes every half second.
A successful reload preserves the viewing camera and pause state. A failed reload retains the last valid scene and
reports the error in the console (and inspector status); saving a corrected file retries it.

| Control | Action |
| --- | --- |
| Drag / scroll | Orbit / zoom; drag looks around in fly mode |
| Tab | Toggle orbit and fly modes |
| W A S D / Q E | Move forward, left, back, right / down and up in fly mode |
| F2 / N | Toggle wireframe / vertex normals |
| H | Show or hide the hierarchy inspector |
| Up / Down | Select a node in the hierarchy |
| V / F | Toggle selected node visibility / frame its hierarchy bounds |
| Space / R / Escape | Pause animation / reset camera / quit |

The inspector shows node hierarchy, geometry/light/camera type, visibility, vertex count, child count and position.
Normals follow animated and skinned geometry. Wireframe uses polygon mode on desktop GL and indexed lines on GLES;
the inspector remains filled and readable in either mode.

`--snapshot <path.bmp>` writes one frame, `--frames <n>` quits after n frames, `--view <yaw> <pitch>` sets angles in
degrees, and `--es` requests OpenGL ES 3.0. `--inspector`, `--normals`, and `--wireframe` enable overlays at launch,
including in snapshots. SDL3 is required: `brew install sdl3` on macOS or `apt install libsdl3-dev` on Debian/Ubuntu.

```sh
swift run scene-viewer model.glb --inspector
swift run scene-viewer model.dae --normals --snapshot model.bmp
```

## Standard asset readers

All readers provide synchronous `decodeScene(_:)` and the async `SceneAssetDecoder.decode(_:)` API, with typed
`SceneFormatError` failures. Local files and their relative resources can be loaded together:

```swift
import Foundation
import SceneFormats

let asset = SceneAssetFile(url: URL(fileURLWithPath: "model.gltf"))
let scene = try asset.load()
// asset.dependencies includes buffers and images loaded by the decoder.
```

For custom storage, pass a `SceneResourceLoader` closure to `GLTFDecoder`, `ColladaDecoder`, or `SCNArchiveDecoder`.
The file loader resolves local file URLs only; decoder closures can implement other storage policies.

| Reader | Implemented |
| --- | --- |
| OBJ / MTL | Streaming line parsing, indexed faces and triangulation, normals, UVs, materials and texture paths |
| glTF 2.0 / GLB | JSON and binary containers, external/data-URI buffers, interleaved and sparse accessors, normalized integers, matrix padding, all core primitive modes, hierarchy/TRS, perspective/orthographic cameras, metallic-roughness materials, PNG/JPEG images, samplers, UV0/UV1, normal/occlusion/emissive maps, opaque/mask/blend alpha |
| glTF animation | STEP, LINEAR and CUBICSPLINE channels; translation, rotation, scale and morph weights; inverse bind matrices and CPU skinning with four joint influences per vertex |
| Collada | XML DOM, namespaces, unit/up-axis conversion, ordered matrix/TRS/look-at transforms, node instances, indexed mesh inputs, triangles/strips/fans/polygons/polylist/lines, profile_COMMON materials and textures, lights and cameras |
| SCN | Binary plist and NSKeyedArchiver/SCNKeyedArchiver UID resolution without instantiating archived classes; nodes, mesh sources/elements, common procedural shapes, color/scalar/path-texture materials, lights and cameras |

The first glTF animation plays automatically. Retrieve `GLTFSceneRuntime` from `scene.systems` to select a clip via
`animationIndex`, seek with `time`, change `speed`, or disable looping. Setting `animationIndex = nil` retains the
pose while skinning continues; `scene.isPaused` pauses updates. CPU skinning prioritizes portability over large-rig
throughput. The GL renderer uses approximate metallic-roughness lighting; environment IBL belongs to Phase 5.

The readers are bounded implementations, not complete replacements for every vendor extension: required glTF
extensions other than `KHR_materials_unlit` and `KHR_lights_punctual` (including compressed geometry), additional joint sets and texture channels beyond UV1 are rejected.
Collada controllers, polygon holes and skew transforms are rejected; Collada animation is not imported. SCN
skinners/morphers, custom geometry classes, embedded platform image objects, constraints, actions and effects are
not reconstructed. SCN procedural tessellation uses SceneGraph defaults. The retained transform representation
uses translation/rotation/scale, so arbitrary shear is not preserved. Unsupported essential geometry features
produce errors instead of executing archived code. USD export and Vulkan remain follow-on work.

PNG and JPEG decoding are pure Swift. The JPEG dependency uses `PureSwift/swift-jpeg`, pinned before its Span API
introduced a macOS 26 deployment requirement, retaining this package's macOS 15 minimum.

Tests cover accessor layouts and malformed references, GLB truncation, skinning and cubic morph animation, Collada
coordinate conversion, SceneKit-generated archive fixtures, JPEG decoding, GPU alpha/texture sampling, inspector
commands, orbit framing, and dependency edits/deletion/recovery. OpenGL tests require a display; physics tests run
on Linux. The desktop viewer and snapshot path have been checked on macOS; GLES/Linux require validation there.

## Converting scene files

`scene-convert` loads local 3DMF, OBJ/MTL, glTF/GLB, Collada and SCN assets through
`SceneAssetFile`, including their supported external resources:

```sh
swift run scene-convert model.obj model.glb
swift run scene-convert scene.scn scene.glb
swift run scene-convert --aspect-ratio 1.777778 scene.scn widescreen.glb
swift run scene-convert --geometry-only scene.scn meshes.glb
swift run scene-convert model.obj model.3dmf
```

GLB export captures the current visible pose, hierarchy (including pivots), names, mesh streams,
submeshes, opacity and materials. PNG/JPEG textures are embedded as lossless PNG images using
PureSwift/swift-png. Supported inputs include UV0/UV1, normal/occlusion/emissive maps, packed shared
metallic-roughness maps, samplers, alpha modes, PBR factors and `KHR_materials_unlit`.
Legacy Phong/Blinn/Lambert materials are approximated as fully rough, nonmetallic PBR surfaces;
their ambient and specular terms are not retained. Sampler anisotropy is not serialized.

Perspective and orthographic cameras and directional/point/spot lights are exported by default.
Cameras retain their names, transforms, clipping planes and projection, including infinite perspective
far planes. Horizontal-FOV and orthographic cameras need a fixed aspect ratio or an explicit
`--aspect-ratio` width/height number; vertical-FOV perspective cameras can follow the destination viewport.

Lights use [KHR_lights_punctual](https://github.com/KhronosGroup/glTF/tree/main/extensions/2.0/Khronos/KHR_lights_punctual).
The reader preserves color, strength, range and spot half angles, and the OpenGL backend applies
inverse-square distance falloff, a range cutoff and squared spot-cone falloff for imported lights.
Internal intensity is 1000 times glTF candela (point/spot) or lux (directional); legacy light export
maps its normalized strength (`intensity / 1000`) to those units. This is an approximation of legacy
lighting: its distance and spot falloff change to glTF's model on export. Existing SCN rendering
continues using the legacy falloff by default. The renderer still uses approximate PBR shading.
Ambient lights, nondefault temperature, shadow settings and custom attenuation have no supported
mapping and produce errors. `--geometry-only` explicitly omits all cameras and lights, and remains
necessary for 3DMF export of scenes containing them.

Animation tracks, physics and GLB backgrounds are not exported. Unsupported vertex streams, separate transparency maps,
independent metallic/roughness textures, texture transforms/intensities, HDR emissive colors,
front-face culling, custom blend/depth state and unresolved textures produce errors.
Hidden branches are omitted. Skin/morph meshes are exported at their current evaluated pose.
USD/USDZ output is not implemented. Binary 3DMF output uses the stricter color-material subset
described below.

Existing outputs are protected unless `--force` is supplied; the input cannot be overwritten.
Encoding completes before writing. New output publication requires a filesystem with hard-link
support; replacement uses an atomic write.

Library callers can use `GLBEncoder().encodeScene(scene)` or
`SceneAssetConverter.convert(from: inputURL, to: outputURL)`.
Both APIs accept an optional `cameraAspectRatio` for viewport-dependent cameras.
GLB tests cover round trips, submeshes, texture pixels and sampling, unlit materials, invalid mesh
data, camera/light round trips, malformed light definitions, SCN conversion, and output preservation
after errors. GPU tests cover inverse-square light falloff, range and spot cutoffs alongside the
existing Apple SCN reference comparisons.

## Writing 3DMF files

`Metafile3D.encoded()` serializes a parsed or edited object tree in its original text or binary
encoding (including little-endian binary files):

```swift
let metafile = try Metafile3D(inputBytes)
let outputBytes = try metafile.encoded()
```

The writer preserves object payloads and hierarchy, including custom binary classes. Resolved references
are expanded inline; output uses normal mode without a table of contents, original labels, or offsets.
Binary payloads must retain their byte order. Text/binary payload conversion is not implemented;
incompatible payloads throw `SceneFormatError.unsupported`.

`ThreeDMFEncoder` exports a static `Scene` as text or binary 3DMF:

```swift
let outputBytes = try ThreeDMFEncoder().encodeScene(scene)
let binaryBytes = try ThreeDMFEncoder(encoding: .binary(.bigEndian)).encodeScene(scene)
// Use .binary(.littleEndian) for little-endian output.
// Also conforms to SceneAssetEncoder:
let asyncOutputBytes = try await ThreeDMFEncoder().encode(scene)
```

Scene export supports triangle lists and strips, indexed or non-indexed, normals, UV channel zero,
node names, transforms, visibility, and color-based Phong/Blinn, Lambert and unlit materials.
Blinn maps to Phong. Submeshes become separate TriMeshes inside display groups, so reloading preserves
world placement and material assignment rather than the exact original node count. Material transparency,
specular color, shininess, emission and face culling are exported. Textures, PBR, lights, cameras,
node opacity and unsupported vertex streams throw an error. Animation and physics are not serialized;
the current node transforms are exported as a static snapshot. Binary export supports the same scene subset
as text, with byte-order-aware floats and integers, padded UTF-8 names, and 8-, 16- or 32-bit TriMesh indices
selected from the vertex count. General conversion of arbitrary metafile payloads remains unsupported.

Round-trip tests cover text and both binary byte orders, geometry, materials, textures, custom classes,
and resolved references. With a Quesa checkout beside the package, tests also rewrite its sample models
and decode the results.

## Acknowledgments

The 3DMF reader is ported from [Quesa](https://github.com/jwwalker/quesa), © 1999–2021 Quesa Developers, under the
BSD 3-Clause License in `LICENSE-Quesa`.
