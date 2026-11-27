// swift-tools-version: 6.4

import PackageDescription

/// Pure-Swift modules build in the Swift 6 language mode, with complete concurrency checking.
let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "swift-scene",
    platforms: [
        // swift-png's floor: Span, which its zlib uses, back-deploys no further.
        .macOS(.v15),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "SceneCore", targets: ["SceneCore"]),
        .library(name: "SceneGraph", targets: ["SceneGraph"]),
        .library(name: "SceneReality", targets: ["SceneReality"]),
        .library(name: "SceneFormats", targets: ["SceneFormats"]),
        .library(name: "SceneUSD", targets: ["SceneUSD"]),
        .library(name: "ScenePhysics", targets: ["ScenePhysics"]),
        .library(name: "SceneSDL", targets: ["SceneSDL"]),
        .executable(name: "scene-convert", targets: ["scene-convert"]),
        .executable(name: "scene-viewer", targets: ["scene-viewer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/PureSwift/SDL.git", branch: "master"),
        // The Swift API is newer than the last tag.
        .package(url: "https://github.com/PureSwift/swift-png.git", branch: "master"),
        // Pin before the Span API so the package retains its macOS 15 deployment target.
        .package(url: "https://github.com/PureSwift/swift-jpeg.git", revision: "902863baa351bc20907c70d6fc076d6954d51edc"),
        // Pre-1.0: source-stable only within a minor version.
        .package(url: "https://github.com/apple/swift-binary-parsing.git", .upToNextMinor(from: "0.0.4")),
    ],
    targets: [
        // Math, spatial primitives, ECS storage, mesh and material descriptors, and the renderer protocols.
        .target(
            name: "SceneCore",
            swiftSettings: swiftSettings
        ),
        // The SceneKit-style retained scene graph.
        .target(
            name: "SceneGraph",
            dependencies: ["SceneCore"],
            swiftSettings: swiftSettings
        ),
        // The RealityKit-style ECS surface.
        .target(
            name: "SceneReality",
            dependencies: ["SceneCore"],
            swiftSettings: swiftSettings
        ),
        // Asset codecs, XML scenes, animation, skinning, and shared resource loading: 3DMF, OBJ, glTF, Collada, SCN.
        .target(
            name: "SceneFormats",
            dependencies: [
                "SceneCore",
                "SceneGraph",
                .product(name: "PNG", package: "swift-png"),
                .product(name: "JPEG", package: "swift-jpeg"),
                .product(name: "BinaryParsing", package: "swift-binary-parsing"),
            ],
            swiftSettings: swiftSettings
        ),
        // OpenUSD: .usda, .usdc and .usdz.
        .target(
            name: "SceneUSD",
            dependencies: ["SceneCore", "SceneGraph", "SceneReality", "SceneFormats"],
            swiftSettings: swiftSettings
        ),
        // Rigid body physics over Box3D, on Linux for now.
        .target(
            name: "ScenePhysics",
            dependencies: [
                "SceneCore",
                "SceneGraph",
                .target(name: "CBox3D", condition: .when(platforms: [.linux])),
            ],
            swiftSettings: swiftSettings
        ),
        // Box3D (github.com/erincatto/box3d), built with CMake and found by pkg-config.
        .systemLibrary(
            name: "CBox3D",
            pkgConfig: "box3d"
        ),
        // The SDL3 host and OpenGL render backend, shared by the asset inspector.
        .target(
            name: "SceneSDL",
            dependencies: [
                "SceneCore",
                .product(name: "SDL3Swift", package: "SDL"),
            ],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "scene-convert",
            dependencies: ["SceneCore", "SceneGraph", "SceneFormats", "SceneUSD"],
            path: "Tools/scene-convert",
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "scene-viewer",
            dependencies: [
                "SceneCore",
                "SceneGraph",
                "SceneFormats",
                "SceneSDL",
                .product(name: "SDL3Swift", package: "SDL"),
            ],
            path: "Tools/scene-viewer",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "SceneCoreTests",
            dependencies: ["SceneCore"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "SceneFormatsTests",
            dependencies: ["SceneCore", "SceneGraph", "SceneFormats"],
            resources: [.copy("Fixtures")],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "SceneUSDTests",
            dependencies: ["SceneUSD", "SceneFormats"],
            resources: [.copy("Fixtures")],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ScenePhysicsTests",
            dependencies: ["SceneCore", "SceneGraph", "ScenePhysics"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "SceneSDLTests",
            dependencies: [
                "SceneCore",
                "SceneGraph",
                "SceneFormats",
                "SceneSDL",
                .product(name: "SDL3Swift", package: "SDL"),
            ],
            resources: [.copy("Fixtures")],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "SceneViewerTests",
            dependencies: ["scene-viewer", "SceneCore", "SceneGraph", "SceneFormats"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "SceneGraphTests",
            dependencies: ["SceneCore", "SceneGraph"],
            swiftSettings: swiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
