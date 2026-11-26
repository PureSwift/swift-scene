/// Identifies a resource a backend may keep on the GPU: the same identifier and revision is the same data.
public struct ResourceKey: Hashable, Sendable {

    public var id: UInt64

    public var revision: UInt64

    public init(id: UInt64, revision: UInt64 = 0) {
        self.id = id
        self.revision = revision
    }

    /// An identifier no other resource has (64 random bits).
    public static func unique() -> ResourceKey {
        ResourceKey(id: .random(in: 1 ... .max))
    }
}

/// What a frame is drawn into: its size in pixels, and how it starts.
public struct RenderTargetDescriptor: Hashable, Sendable {

    public var width: Int

    public var height: Int

    /// Linear RGBA; nil leaves what is there.
    public var clearColor: SIMD4<Float>?

    public init(width: Int, height: Int, clearColor: SIMD4<Float>? = SIMD4(0, 0, 0, 1)) {
        self.width = width
        self.height = height
        self.clearColor = clearColor
    }

    public var aspectRatio: Float { height > 0 ? Float(width) / Float(height) : 1 }
}

/// Where a frame is seen from.
public struct CameraUniforms: Hashable, Sendable {

    public var viewMatrix: Matrix4x4

    public var projectionMatrix: Matrix4x4

    public init(viewMatrix: Matrix4x4, projectionMatrix: Matrix4x4) {
        self.viewMatrix = viewMatrix
        self.projectionMatrix = projectionMatrix
    }

    public var viewProjectionMatrix: Matrix4x4 { projectionMatrix * viewMatrix }

    /// The eye's position in world space.
    public var position: SIMD3<Float> { (viewMatrix.inverse ?? .identity).translation }

    public var frustum: Frustum { Frustum(viewProjection: viewProjectionMatrix) }
}

/// A light where it is in the world.
public struct LightInstance: Hashable, Sendable {

    public var light: LightDescriptor

    public var worldTransform: Matrix4x4

    public init(light: LightDescriptor, worldTransform: Matrix4x4) {
        self.light = light
        self.worldTransform = worldTransform
    }

    public var position: SIMD3<Float> { worldTransform.translation }

    /// The way it shines: its -z axis.
    public var direction: SIMD3<Float> { (-worldTransform.columns.2.xyz).normalized }
}

/// One run of a mesh with one material at one place.
public struct DrawCall: Hashable, Sendable {

    /// The mesh's key, for a backend to keep its buffers by; nil for an immediate draw, uploaded every time.
    public var meshKey: ResourceKey?

    public var mesh: MeshBuffer

    public var submeshIndex: Int

    public var material: MaterialDescriptor

    public var worldTransform: Matrix4x4

    /// The opacity inherited from the node and its ancestors.
    public var opacity: Float

    public init(
        meshKey: ResourceKey?,
        mesh: MeshBuffer,
        submeshIndex: Int,
        material: MaterialDescriptor,
        worldTransform: Matrix4x4,
        opacity: Float = 1
    ) {
        self.meshKey = meshKey
        self.mesh = mesh
        self.submeshIndex = submeshIndex
        self.material = material
        self.worldTransform = worldTransform
        self.opacity = opacity
    }

    public var submesh: Submesh { mesh.submeshes[submeshIndex] }
}

/// A command in a frame.
public enum RenderCommand: Hashable, Sendable {
    case setCamera(CameraUniforms)
    case setLights([LightInstance])
    case draw(DrawCall)
}

/// What a frame's commands are recorded into. A retained scene's renderer and immediate-mode code both
/// encode into one, and its backend draws what it holds.
public protocol FrameCommandBuffer {

    mutating func encode(_ command: RenderCommand)
}

public extension FrameCommandBuffer {

    mutating func setCamera(_ camera: CameraUniforms) {
        encode(.setCamera(camera))
    }

    mutating func setLights(_ lights: [LightInstance]) {
        encode(.setLights(lights))
    }

    mutating func draw(_ call: DrawCall) {
        encode(.draw(call))
    }

    /// Draws every run of a mesh nothing keeps: QuickDraw 3D's immediate mode.
    mutating func drawImmediate(_ mesh: MeshBuffer, materials: [MaterialDescriptor], transform: Matrix4x4) {
        for index in mesh.submeshes.indices {
            let material = materials.isEmpty ? .default : materials[max(mesh.submeshes[index].materialIndex, 0) % materials.count]
            draw(DrawCall(meshKey: nil, mesh: mesh, submeshIndex: index, material: material, worldTransform: transform))
        }
    }
}

/// A frame's commands, as a list.
public struct RecordedCommandBuffer: FrameCommandBuffer, Hashable, Sendable {

    public var target: RenderTargetDescriptor

    public var commands: [RenderCommand] = []

    public init(target: RenderTargetDescriptor) {
        self.target = target
    }

    public mutating func encode(_ command: RenderCommand) {
        commands.append(command)
    }

    public var drawCalls: [DrawCall] {
        commands.compactMap { if case .draw(let call) = $0 { call } else { nil } }
    }
}

public enum RenderError: Error, Hashable, Sendable {
    /// The target can't be drawn into now: a window gone, a surface lost.
    case targetUnavailable
    case backendFailure(String)
}

/// Something that draws frames: OpenGL, Vulkan or Metal, or nothing at all.
public protocol RenderBackend: AnyObject {

    associatedtype CommandBuffer: FrameCommandBuffer

    /// Starts a frame into the target.
    func beginFrame(target: RenderTargetDescriptor) throws(RenderError) -> CommandBuffer

    /// Draws the frame's commands.
    func endFrame(_ commands: consuming CommandBuffer) throws(RenderError)
}

/// A backend that draws nothing and keeps the last frame: for tests, tools and servers.
public final class HeadlessRenderBackend: RenderBackend {

    public private(set) var lastFrame: RecordedCommandBuffer?

    public private(set) var frameCount = 0

    public init() {}

    public func beginFrame(target: RenderTargetDescriptor) throws(RenderError) -> RecordedCommandBuffer {
        RecordedCommandBuffer(target: target)
    }

    public func endFrame(_ commands: consuming RecordedCommandBuffer) throws(RenderError) {
        lastFrame = commands
        frameCount += 1
    }
}
