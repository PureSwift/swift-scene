# Generated reference fixtures

- `reference.scn`: Written by Apple's SceneKit `SCNScene.write(to:options:delegate:progressHandler:)` on macOS. Contains a parent at (1, 2, 3), a custom indexed triangle with a red material, a box of dimensions (2, 3, 4), a camera and an omni light. Exercises actual keyed-archive layout independently of the decoder.
- `shapes.scn`: Written by SceneKit with sphere, cylinder, cone, torus, capsule and plane geometries. Each material references `checker.png` and has roughness 0.4; the test supplies JPEG bytes through the resource callback to verify signature-based decoding. The plane is 2 by 3 units.
- `red.jpg`: An 8 by 8 solid-red RGB image, generated from a PPM and encoded with macOS `sips`. Used to verify the independent Swift JPEG decoder with lossy-color tolerance.

These fixtures contain only generated geometry, materials and pixel data. They require no Apple framework at test runtime.

`References/` contains generated keyed archives for nested relative references, repeated instances, axis-angle rotation, and the older `NSData.NS.data` mesh-buffer representation found in the tutorial corpus. `root.scn` references `models/branch.scn` twice; that archive uses the editor’s `file:///` base marker and references `../assets/leaf.scn`, whose material loads `textures/red.jpg`. Regenerate with `python3 Tests/SceneFormatsTests/Fixtures/References/generate.py`. These fixtures derive only from this project's existing generated `reference.scn` and `red.jpg`; no tutorial assets are redistributed.
