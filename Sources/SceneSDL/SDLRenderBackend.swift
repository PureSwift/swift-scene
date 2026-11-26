import SceneCore
import SDL3Swift

/// A window with an OpenGL context, as a `RenderBackend`: each frame's commands are drawn into the window and
/// shown.
///
/// SDL's video functions are the main thread's, so a backend is made, used and released there.
public final class SDLRenderBackend: RenderBackend {

    /// Which OpenGL to ask for.
    public enum Profile: Hashable, Sendable {
        /// OpenGL 3.3 Core: desktop Linux, Windows and macOS.
        case core
        /// OpenGL ES 3.0: embedded Linux, Raspberry Pi, Android.
        case es
    }

    public let window: SDLWindow

    public let renderer: OpenGLRenderer

    public let profile: Profile

    private let context: SDLGLContext

    /// Opens a window with an OpenGL context. SDL's video subsystem must be initialized.
    public init(
        title: String,
        width: Int,
        height: Int,
        profile: Profile = .core,
        sampleCount: Int32 = 4,
        isResizable: Bool = true,
        isHidden: Bool = false
    ) throws(SDLRenderBackendError) {
        do {
            switch profile {
            case .core:
                try SDL.glSetAttribute(.contextProfileMask, GLAttribute.Profile.core.rawValue)
                try SDL.glSetAttribute(.contextMajorVersion, 3)
                try SDL.glSetAttribute(.contextMinorVersion, 3)
            case .es:
                try SDL.glSetAttribute(.contextProfileMask, GLAttribute.Profile.es.rawValue)
                try SDL.glSetAttribute(.contextMajorVersion, 3)
                try SDL.glSetAttribute(.contextMinorVersion, 0)
            }
            try SDL.glSetAttribute(.depthSize, 24)
            if sampleCount > 1 {
                try SDL.glSetAttribute(.multisampleBuffers, 1)
                try SDL.glSetAttribute(.multisampleSamples, sampleCount)
            }
            var options: BitMaskOptionSet<SDLWindow.Option> = [.opengl, .highPixelDensity]
            if isResizable { options.insert(.resizable) }
            if isHidden { options.insert(.hidden) }
            let window = try SDLWindow(title: title, width: width, height: height, options: options)
            let context = try SDLGLContext(window: window)
            try context.makeCurrent(in: window)
            // Wait for the display; not every driver can.
            try? SDL.glSetSwapInterval(1)
            self.window = window
            self.context = context
        } catch {
            throw .sdl(error)
        }
        self.profile = profile
        do {
            self.renderer = try OpenGLRenderer(loader: { name in
                SDL.glProcAddress(name).map { unsafeBitCast($0, to: UnsafeRawPointer.self) }
            }, isES: profile == .es)
        } catch {
            throw .gl(error)
        }
    }

    deinit {
        // The renderer's objects go while their context is still current.
        try? context.makeCurrent(in: window)
        renderer.releaseResources()
    }

    /// A target the size of the window's drawable, in pixels.
    public func target(clearColor: SIMD4<Float>? = SIMD4(0, 0, 0, 1)) -> RenderTargetDescriptor {
        let size = window.drawableSize
        return RenderTargetDescriptor(width: size.width, height: size.height, clearColor: clearColor)
    }

    // MARK: RenderBackend

    public func beginFrame(target: RenderTargetDescriptor) throws(RenderError) -> RecordedCommandBuffer {
        guard target.width > 0, target.height > 0 else { throw .targetUnavailable }
        do {
            try context.makeCurrent(in: window)
        } catch {
            throw .backendFailure(error.errorMessage)
        }
        return RecordedCommandBuffer(target: target)
    }

    public func endFrame(_ commands: consuming RecordedCommandBuffer) throws(RenderError) {
        renderer.draw(commands)
        do {
            try window.glSwap()
        } catch {
            throw .backendFailure(error.errorMessage)
        }
    }

    /// Draws a frame without showing it and reads it back: for screenshots.
    public func snapshot(_ commands: RecordedCommandBuffer) throws(RenderError) -> ImageBuffer {
        do {
            try context.makeCurrent(in: window)
        } catch {
            throw .backendFailure(error.errorMessage)
        }
        renderer.draw(commands)
        return renderer.readPixels(width: commands.target.width, height: commands.target.height)
    }
}

/// Why an SDL render backend couldn't be made.
public enum SDLRenderBackendError: Error {
    case sdl(SDLError)
    case gl(GLError)
}

extension SDLRenderBackendError: CustomStringConvertible {

    public var description: String {
        switch self {
        case .sdl(let error): "SDL: \(error.errorMessage)"
        case .gl(let error): "OpenGL: \(error)"
        }
    }
}

private extension GLAttribute {

    /// `SDL_GL_DEPTH_SIZE`, which the wrapper doesn't name: its place in `SDL_GLAttr`.
    static var depthSize: GLAttribute { GLAttribute(rawValue: 6) }
}
