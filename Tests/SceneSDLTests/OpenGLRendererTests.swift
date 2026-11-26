import Testing
import SceneCore
import SceneSDL
import SDL3Swift

/// Whether a window can be opened here: not on a headless build machine. SDL's video starts on the main thread.
@MainActor
private func canOpenWindow() -> Bool {
    do {
        try SDL.initialize(subSystems: [.video])
        return true
    } catch {
        return false
    }
}

// One window at a time: SDL's video functions want a single thread.
@Suite(.serialized, .enabled("Needs a display") { await canOpenWindow() })
@MainActor
struct OpenGLRendererTests {

    private func makeBackend() throws -> SDLRenderBackend {
        try SDLRenderBackend(title: "test", width: 64, height: 64, sampleCount: 0, isResizable: false, isHidden: true)
    }

    /// A unit quad facing +z at the origin.
    private let quad = MeshBuffer(
        vertexCount: 4,
        streams: [
            VertexStream(semantic: .position, vectors: [SIMD3<Float>(-1, -1, 0), SIMD3(1, -1, 0), SIMD3(1, 1, 0), SIMD3(-1, 1, 0)]),
            VertexStream(semantic: .textureCoordinate(0), vectors: [SIMD2<Float>(0, 1), SIMD2(1, 1), SIMD2(1, 0), SIMD2(0, 0)]),
        ],
        indices: IndexBuffer([0, 1, 2, 0, 2, 3]),
        submeshes: [Submesh(range: 0..<6, materialIndex: 0)]
    )

    private func pixel(_ image: ImageBuffer, x: Int, y: Int) -> SIMD4<UInt8> {
        let p = y * image.bytesPerRow + x * 4
        return SIMD4(image.pixels[p], image.pixels[p + 1], image.pixels[p + 2], image.pixels[p + 3])
    }

    @Test func clearsToColor() throws {
        let backend = try makeBackend()
        let target = RenderTargetDescriptor(width: 64, height: 64, clearColor: SIMD4(1, 0, 0, 1))
        let image = try backend.snapshot(RecordedCommandBuffer(target: target))
        #expect(pixel(image, x: 32, y: 32) == SIMD4(255, 0, 0, 255))
    }

    @Test func drawsUnlitQuadOverClear() throws {
        let backend = try makeBackend()
        var commands = RecordedCommandBuffer(target: RenderTargetDescriptor(width: 64, height: 64, clearColor: SIMD4(0, 0, 0, 1)))
        commands.setCamera(CameraUniforms(
            viewMatrix: .lookAt(eye: SIMD3(0, 0, 4), target: .zero, up: SIMD3(0, 1, 0)),
            projectionMatrix: .perspective(verticalFieldOfView: .pi / 3, aspectRatio: 1, near: 0.1, far: 10)
        ))
        commands.drawImmediate(quad, materials: [.unlit(color: SIMD4(0, 1, 0, 1))], transform: .identity)
        let image = try backend.snapshot(commands)
        // The middle is the quad's, the corner the clear colour's.
        #expect(pixel(image, x: 32, y: 32) == SIMD4(0, 255, 0, 255))
        #expect(pixel(image, x: 0, y: 0) == SIMD4(0, 0, 0, 255))
    }

    @Test func samplesTextureRightWayUp() throws {
        let backend = try makeBackend()
        // Two rows: red on top, blue below.
        let texture = ImageBuffer(width: 1, height: 2, format: .rgba8, pixels: [255, 0, 0, 255, 0, 0, 255, 255])
        var material = MaterialDescriptor.unlit(color: SIMD4(1, 1, 1, 1))
        material.diffuse = MaterialProperty(.texture(.image(texture)), sampler: TextureSampler(minificationFilter: .nearest, magnificationFilter: .nearest))
        var commands = RecordedCommandBuffer(target: RenderTargetDescriptor(width: 64, height: 64))
        commands.setCamera(CameraUniforms(viewMatrix: .identity, projectionMatrix: .identity))
        commands.drawImmediate(quad, materials: [material], transform: .identity)
        let image = try backend.snapshot(commands)
        #expect(pixel(image, x: 32, y: 8) == SIMD4(255, 0, 0, 255))
        #expect(pixel(image, x: 32, y: 56) == SIMD4(0, 0, 255, 255))
    }
}
