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
   (SDL3, GL)     (3DMF, …)   (USD/USDZ)       (Box3D)
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
| `SceneUSD` | Pure-Swift USDZ I/O, static USDA parsing, polygon mesh/transform import and static triangle export; USDC and composition remain planned |
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

`scene-viewer [file]` opens `.3dmf`, `.obj`, `.gltf`, `.glb`, `.dae`, `.scn`, or standalone static
USDA (`.usda`/`.usd`, including inside `.usdz`), or a rotating textured demo without a file.
USD supports directly bound Preview Surface constants and packaged diffuse and emissive textures;
`--geometry-only` discards unsupported shading.
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
swift run scene-viewer --geometry-only model.usdz --inspector
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
extensions other than `KHR_materials_unlit`, `KHR_materials_emissive_strength` and `KHR_lights_punctual` (including compressed geometry), additional joint sets and texture channels beyond UV1 are rejected.
Collada controllers, polygon holes and skew transforms are rejected; Collada animation is not imported. SCN
skinners/morphers, custom geometry classes, embedded platform image objects, constraints, actions and effects are
not reconstructed. SCN procedural tessellation uses SceneGraph defaults. The retained transform representation
uses translation/rotation/scale, so arbitrary shear is not preserved. Unsupported essential geometry features
produce errors instead of executing archived code. Vulkan remains follow-on work.

PNG and JPEG decoding are pure Swift. The JPEG dependency uses `PureSwift/swift-jpeg`, pinned before its Span API
introduced a macOS 26 deployment requirement, retaining this package's macOS 15 minimum.

Tests cover accessor layouts and malformed references, GLB truncation, skinning and cubic morph animation, Collada
coordinate conversion, SceneKit-generated archive fixtures, JPEG decoding, GPU alpha/texture sampling, inspector
commands, orbit framing, and dependency edits/deletion/recovery. OpenGL tests require a display; physics tests run
on Linux. The desktop viewer and snapshot path have been checked on macOS; GLES/Linux require validation there.

## Converting scene files

`scene-convert` loads local 3DMF, OBJ/MTL, glTF/GLB, Collada, SCN and static USDA/USDZ assets through
`SceneAssetFile`, including their supported external resources:

```sh
swift run scene-convert model.obj model.glb
swift run scene-convert scene.scn scene.glb
swift run scene-convert --aspect-ratio 1.777778 scene.scn widescreen.glb
swift run scene-convert --geometry-only scene.scn meshes.glb
swift run scene-convert model.obj model.3dmf
swift run scene-convert --geometry-only model.usdz model.glb
swift run scene-convert --geometry-only model.3dmf model.usdz
swift run scene-convert --geometry-only model.dae model.usda
swift run scene-convert colored.obj colored.usdz
```

GLB export captures the current visible pose, hierarchy (including pivots), names, mesh streams,
submeshes, opacity and materials. PNG/JPEG textures are embedded as lossless PNG images using
PureSwift/swift-png. Supported inputs include UV0/UV1, normal/occlusion/emissive maps, packed shared
metallic-roughness maps, samplers, alpha modes, PBR factors and `KHR_materials_unlit`.
HDR emission uses `KHR_materials_emissive_strength`: export normalizes the core emissive RGB
factor and stores its peak as strength; import restores HDR constants or texture multipliers.
This preserves HDR emission during USDZ-to-GLB conversion. Strength defaults to 1 and must be
finite and nonnegative; the extension cannot be combined with `KHR_materials_unlit`.

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
independent metallic/roughness textures, texture transforms/intensities,
front-face culling, custom blend/depth state and unresolved textures produce errors.
Hidden branches are omitted. Skin/morph meshes are exported at their current evaluated pose.
Binary 3DMF output uses the stricter color-material subset
described below.

USD export writes `.usda`, text `.usd`, or `.usdz` containing `scene.usda`. It preserves static
visible hierarchy, affine transforms (including pivots), triangle geometry, normals and UV0.
Constant materials are exported as Preview Surface shaders; USDZ also embeds diffuse and emissive textures.
Unsupported texture features, cameras,
lights and node opacity require `--geometry-only` to explicitly discard them. Other unsupported
vertex streams are also discarded with that option; double-sided surfaces are retained.

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

## USD foundation

`SceneUSD.USDZArchive` reads and writes the uncompressed ZIP container defined by the
[OpenUSD USDZ specification](https://openusd.org/release/spec_usdz.html). It is pure Swift,
uses no OpenUSD binaries or C++ interoperability, and is tested on macOS and Linux CI.

```swift
import SceneUSD

let archive = try USDZArchive(entries: [
    .init(path: "root.usda", data: Array("#usda 1.0\ndef Xform \"World\" {}\n".utf8))
])
let bytes = try archive.encoded()
let loaded = try USDZArchive(bytes)
let root = loaded.defaultLayer
let layerBytes = loaded["root.usda"]?.data
```

Entry data uses `ArraySlice<UInt8>` views into the input archive; use each slice's `startIndex`
or iterate it instead of assuming zero-based indices. Lookup is by exact canonical relative path.
Physical entry order determines the optional default layer. Asset-only and empty packages are
supported. Encoding preserves member order and bytes, with fixed timestamps and 64-byte alignment;
ZIP comments and extra metadata are not preserved.

The reader validates local/central headers, member ranges, alignment, UTF-8/ASCII names and CRC-32.
It rejects duplicate or unsafe paths, unsupported member extensions, compression, encryption,
ZIP64, multi-disk archives, data descriptors, preambles, and directory/symlink entries.
It never extracts files to disk. The checked-in fixture is independently generated with Python's ZIP writer.

`USDStage` parses standalone static USDA definitions from UTF-8 bytes or a package's default layer:

```swift
let stage = try USDStage(usda: Array("#usda 1.0\ndef Xform \"World\" {}\n".utf8))
let packagedStage = try USDStage(archive: loaded)
let world = stage.prim(at: "/World")
let definitions = stage.traverse()
let points = world?[property: "points"]?.value
```

The stage retains prim and property order, declared type names, custom/variability qualifiers,
metadata, typed dictionaries, arrays, tuples, relationship targets, asset paths and value blocks.
`USDValue.number` preserves numeric spelling rather than converting integers through floating point.
One explicit, prepend or append `apiSchemas` list per prim is accepted and normalized to its
authored token order for the standalone layer; this does not implement composition across layers.
This is a syntax model: it does not validate schema-specific attribute types, apply schema defaults,
resolve assets or evaluate transforms. Traversal includes inactive authored definitions.

The current subset requires ASCII prim/property identifiers, supports UTF-8 strings and asset paths,
and limits combined hierarchy/value nesting to 32 levels. Composition arcs, overrides/classes,
variants, general list operations, non-shading connections, time samples, triple-delimited asset paths and uncommon
string escapes throw errors. A mesh fixture serialized by OpenUSD 26.11, malformed input tests,
truncation tests and byte-mutation tests exercise the parser without a native USD dependency.

`USDSceneDecoder` converts that static subset into SceneGraph and can feed existing encoders:

```swift
let scene = try USDSceneDecoder(geometryOnly: true).decodeScene(stage)
let glb = try GLBEncoder().encodeScene(scene)
// decodeScene(bytes) also detects USDA or a USDZ package containing USDA.
```

Import supports Xform/Scope hierarchies, static cameras and polygon meshes with `subdivisionScheme = "none"`,
including concave faces, hole indices, handedness, double-sided surfaces, normals and `primvars:st`.
Vertex streams are expanded across triangle corners to preserve normal/UV seams. Constant, uniform,
vertex, varying and face-varying interpolation are supported, along with indexed UVs. Missing normals
are generated per face. UVs are converted to the engine's top-origin convention.

Transforms support ordered translate/scale, axis and six Euler rotations (degrees), orient quaternions,
affine matrices, inverse operations and reset stacks. Shear/reflection matrices use SceneGraph pivots
when TRS decomposition would lose them; unrepresentable singular matrices throw. Stage units default
to centimetres and convert to metres; Y-up and Z-up convert to the engine's Y-up convention.
Inactive subtrees are omitted and visibility is inherited through nodes.

Material import resolves direct all-purpose bindings, including inheritance and descendant overrides,
to a single `UsdPreviewSurface` shader. Diffuse/emissive colors, metallic/roughness, alpha
and positive opacity masks map to material descriptors. The exporter's emission-only unlit approximation
is recognized. Binding and connection targets currently require absolute paths. Unbound shading
definitions are ignored. Collection/purpose bindings, stronger-than-descendants bindings, arbitrary
shader input connections, specular workflow and nondefault clearcoat/IOR/normal/displacement/occlusion
inputs throw; `geometryOnly: true` discards shading in favor of default materials.
Subdivision, other primvars, inherited primvars, skeletal deformation,
non-default purposes and unsupported prim types throw. Both tools register the USD decoder and retain
their import options across reloads. Viewer cameras and lights remain outside the USD unit/axis transform.
Standalone USD image dependencies are watched for changes; USDZ watches its package. External USD layer references remain unsupported.
USDC, composition and general shading network evaluation remain unimplemented.
Apple SwiftUsd is not a dependency.

`USDSceneEncoder` exports the current visible pose to deterministic USDA or a USDZ with a
`scene.usda` default layer and optional PNG textures. It authors a `Scene` default prim,
Y-up coordinates and metre units. Stable
prim identifiers avoid name collisions; original names are stored in `displayName` and restored
by the decoder. Each submesh becomes a separate Mesh child, so reimport preserves the visual
hierarchy rather than exact node topology. Indexed and nonindexed triangle lists/strips are
supported; degenerate triangles are omitted. Normals and UV0 use vertex interpolation, with
UV V converted back to USD's bottom-origin convention. Hierarchies are limited to 25 node levels.

```swift
let bytes = try USDSceneEncoder(encoding: .usdz, geometryOnly: true).encodeScene(scene)
```

The encoder emits per-submesh `MaterialBindingAPI` bindings and `UsdPreviewSurface` shaders for
nondefault constant materials. It preserves linear diffuse/emissive colors, metallic/roughness
constants and factors, and material alpha (opaque, blend/legacy, or positive mask thresholds).
Legacy Phong/Blinn/Lambert surfaces become fully rough nonmetallic PBR; their ambient/specular
terms and shininess are not retained. Unlit surfaces are approximated using emission, zero diffuse
and IOR 1. Material names use `displayName`. Default materials need no authored shader.

USDZ diffuse and emissive textures accept in-memory images or local PNG/JPEG paths (JPEG uses PureSwift/swift-jpeg).
Images are encoded as PNG and deduplicated within the package. A `UsdUVTexture` and
`UsdPrimvarReader_float2` connect UV0 to diffuse/emissive RGB and, unless opaque, diffuse texture alpha.
Independent linear color/alpha factors are applied through texture scale; emissive RGB factors may exceed 1 for HDR emission; source pixels are marked sRGB.
PNG rows retain their original orientation while mesh UV V is flipped for USD. Clamp, repeat,
mirror and transparent-black border wrapping are supported. Linear min/mag filters and unit
anisotropy are required; mip filtering is left to the consuming renderer. Standalone USDA
texture output, secondary UVs and texture transforms remain unsupported.
USDZ import accepts these diffuse RGB/alpha and emissive RGB graphs, including PNG/JPEG package members, explicit
sRGB color space, texture scale, zero bias, wrap modes and a direct `st` primvar reader. Image
paths resolve relative to the default layer inside the package; USDZ never opens external files.
Shared diffuse/opacity sampling is supported; emissive image alpha never controls surface opacity.
Images shared between diffuse and emissive slots are deduplicated, while samplers and factors remain independent. Constant opacity ignores image alpha, and missing
UVs, missing/corrupt images, unsupported color spaces or other graph structures produce errors.
Standalone USDA image loading is available through an explicit resource loader or the file registrations described below.

Unlit diffuse textures round-trip through USDZ using the emission-only Preview Surface
approximation (zero diffuse, IOR 1). RGB connects to emission; blended and masked materials
connect the same texture alpha to opacity. Color factors, diffuse intensity and inherited
node opacity are preserved without modifying source pixels. Opaque import clears unused
image alpha. Additional emission, normal/occlusion maps and other unlit texture combinations
remain unsupported. Import recognizes this restricted graph and restores an unlit material,
including `KHR_materials_unlit` when subsequently exported to GLB.

Packed metallic/roughness maps also round-trip through USDZ: roughness uses green, metallic
uses blue, and both connections share one `UsdUVTexture` in raw color space. Their independent
factors are stored in the corresponding scale channels. Export requires a physically based
material with identical metalness/roughness texture properties, including sampler and UV settings.
Separate maps, single connected channels, different channel packing and sRGB data maps are rejected.
The packed image may share storage with color textures while each shader retains its own color space.

Tangent-space normal maps also round-trip through USDZ using raw RGB, signed scale/bias and
uniform nonnegative XY strength. Export negates tangent-space Y to compensate for the mesh UV V
flip. Import accepts that encoding or standard positive-Y USD normal decoding, converting the
green channel for the latter. Image alpha is ignored. Normal maps require UV0; custom tangent
streams, anisotropic XY strength, object-space normals and unlit normal maps remain unsupported.
GLB conversion preserves normal strength through `normalTexture.scale`.

Occlusion maps round-trip through USDZ using raw red-channel sampling. Strength in 0...1
is encoded as scale and complementary bias, preserving the renderer's interpolation from
unoccluded to sampled occlusion. Packed ORM images are shared without changing their pixels.
GLB conversion retains this value through `occlusionTexture.strength`. Unlit occlusion maps
and nonstandard occlusion shader graphs remain unsupported.

Diffuse property intensity is baked into RGB constants or texture scale, leaving alpha unchanged.
Constant emission intensity is likewise baked into emission RGB, including HDR values. Import
normalizes these multipliers into colors/factors with unit property intensity. Intensities must
be finite and nonnegative; the final diffuse RGB must remain in 0...1. Emissive textures continue
to use `emissionFactor`; non-unit emissive texture intensity is rejected.

Transparency maps, other unsupported property intensities, custom culling/blending/depth
state and unsupported light types remain unsupported. Explicit `geometryOnly: true` drops
material shading and those node properties. Exported constant materials can be imported without
`geometryOnly`; arbitrary shader graphs remain unsupported. Transparent Preview Surface materials
use the renderer's alpha blending approximation rather than full optical transmission.
Static perspective and orthographic cameras round-trip through USDA/USDZ, preserving their
projection and transforms. Export requires a fixed `CameraDescriptor.aspectRatio` or
`USDSceneEncoder(cameraAspectRatio:)`; the conversion CLI forwards `--aspect-ratio`.
Both vertical and horizontal field-of-view inputs are supported; import normalizes to vertical.
Apertures and focal lengths follow [USD camera units](https://openusd.org/release/api/class_usd_geom_camera.html).
Stage unit and axis conversion stays in the imported root transform, so local lens distances
are not converted twice. Camera names use `displayName`. A node carrying both geometry and
a camera exports a separate Camera child.

Only symmetric lenses with finite clipping planes are supported. Aperture offsets, depth of
field, motion blur, stereo roles and custom clipping planes are rejected. Infinite far planes
require an explicit finite distance before export. Geometry-only mode discards camera lenses
while retaining their child geometry and transforms.

Directional lights round-trip as zero-angle `DistantLight` prims, preserving color, direction,
names and normalized strength (`LightDescriptor.intensity / 1000`). Export enables light
normalization and explicitly disables shadows through `ShadowAPI`. Import folds exposure
into intensity using `2^exposure`. This follows the zero-angle distant-light subset of
[USD LightAPI](https://openusd.org/release/user_guides/schemas/usdLux/LightAPI.html).
Legacy directional strength uses the same numerical mapping as GLB export.

Import requires zero angle and explicitly disabled shadows. Nonzero angular extent, temperature
controls, custom diffuse/specular contributions, filters, light linking and connected inputs
are rejected. Ambient, spot and area lights remain unsupported. Geometry-only mode
discards directional lights while retaining their transforms and child geometry.

Inverse-square point lights without a range cutoff round-trip as normalized `SphereLight`
prims with `treatAsPoint = true`, zero radius and disabled shadows. Intensity maps numerically
as `LightDescriptor.intensity / 1000`, following
[OpenUSD Storm's point-source approximation](https://raw.githubusercontent.com/PixarAnimationStudios/OpenUSD/release/pxr/imaging/hdSt/light.cpp).
This is a documented brightness approximation, not a guarantee of photometric equivalence
across USD renderers. Import folds exposure into intensity and preserves position and color.
Legacy distance falloff, range cutoffs, nonzero radii, shaping, shadows and unnormalized sphere
lights are rejected. Geometry-only mode omits these lights.

Inherited node opacity is baked into each exported material's constant opacity or diffuse texture
alpha scale. Shared source materials remain unchanged. Legacy/blended surfaces multiply node
opacity by material alpha and transparency; masked surfaces apply their cutoff after that
multiplication, while explicit opaque surfaces ignore alpha, matching the renderer. Fully
transparent node subtrees are omitted. Reimport preserves the visible opacity through materials,
rather than reconstructing the original node opacity values. Geometry-only export ignores opacity.

Animation tracks, skin bindings, physics and backgrounds are not serialized; deformed mesh data
and transforms capture the current pose. Round-trip tests cover transforms, escaped names,
submeshes, malformed geometry, deterministic bytes and safe file replacement.

Standalone USDA may reference relative PNG/JPEG image paths when a resource resolver is supplied.
Use `USDSceneDecoder(resourceLoader:)` for library-owned resources, or
`resourceFileDecoders` with `SceneAssetFile`/`SceneAssetConverter` for local file resolution and
dependency tracking. The CLI and viewer use these registrations. Paths are resolved relative
to the layer file, including parent-directory references; literal spaces, percent signs and
hash characters are encoded for the resource loader. Absolute paths, URL schemes and nested
package references are unsupported. Missing or corrupt images fail conversion before output
is written. Byte-only decoding without a resolver still performs no external I/O.

Library clients opt into USD file loading with per-instance registrations, without global mutable state:

```swift
let decoders = USDSceneDecoder(geometryOnly: true).resourceFileDecoders
let asset = SceneAssetFile(url: inputURL, resourceDecoders: decoders)
let loadedScene = try asset.load()
let encoders = USDSceneEncoder(geometryOnly: true).fileEncoders
try SceneAssetConverter.convert(from: inputURL, to: outputURL,
                                encoders: encoders, resourceDecoders: decoders)
```
