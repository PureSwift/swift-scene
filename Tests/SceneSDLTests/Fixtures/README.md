# SceneKit render comparison

`comparison.scn` is a committed SceneKit keyed archive, generated from the project's `reference.scn` fixture with blue (sRGB 0.2, 0.5, 0.85) and red (1, 0.15, 0.1) Lambert materials, a directional light of intensity 800 and ambient light of intensity 200. Geometry and pixel data are generated, with no third-party assets.

`apple-scenekit.png` is the independent reference: Apple's Metal SceneKit renderer, 1280×720, four-sample antialiasing, macOS 27. The test renders the same archived scene through the Swift decoder and SDL/OpenGL backend. Camera position is (5.3448873, 4.2767897, 8.891592), looking at (0.5, 0.75, 0.5), vertical field of view 60°, near 0.01, far 1000. Background is linear RGB (0.05, 0.06, 0.08), encoded with gamma 2.2 for the Apple reference.

The comparison requires silhouette intersection-over-union above 0.98 and foreground mean absolute RGB error below 6 on a 0–255 scale. The corrected importer measures approximately 2.27; the original sRGB-as-linear bug measured 40.98. Blank images fail separately. These tolerances allow antialiasing and driver differences without hiding the color regression.

To regenerate the archive and Apple reference from the repository root on macOS:

```sh
xcrun swift Tests/SceneSDLTests/Fixtures/generate-reference.swift
```

The normal test only reads the committed files; it does not need SceneKit. SDL display tests may skip on headless machines. macOS CI sets `SCENE_REQUIRE_RENDER_TESTS=1` so unavailable graphics fails instead of silently skipping the comparison.

The same generator also writes `textured.scn`, `normal-mapped.scn`, and `multi-material.scn`, with corresponding `*-apple.png` references. `quadrants.png` is an asymmetric four-color texture that exposes UV orientation mistakes; `tilted-normal.png` encodes a non-flat tangent-space normal. The material fixture assigns distinct colors to the six box faces. All three use the same camera, image size and tolerances as the original comparison. Each test additionally removes its covered feature and checks that the resulting render exceeds the error threshold, preventing an insensitive reference from passing unnoticed.
