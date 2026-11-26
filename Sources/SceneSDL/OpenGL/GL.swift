// OpenGL 3.3 Core / OpenGL ES 3.0, loaded by name at run time through a context's procedure lookup
// (`SDL_GL_GetProcAddress`), so nothing links against a platform's GL library or includes its headers.

typealias GLenum = UInt32
typealias GLuint = UInt32
typealias GLint = Int32
typealias GLsizei = Int32
typealias GLfloat = Float
typealias GLboolean = UInt8
typealias GLbitfield = UInt32
typealias GLsizeiptr = Int

/// The constants used, from the OpenGL registry.
enum GLConstant {
    static let false_: GLboolean = 0
    static let true_: GLboolean = 1

    static let depthBufferBit: GLbitfield = 0x0000_0100
    static let colorBufferBit: GLbitfield = 0x0000_4000

    static let points: GLenum = 0x0000
    static let lines: GLenum = 0x0001
    static let lineStrip: GLenum = 0x0003
    static let triangles: GLenum = 0x0004
    static let triangleStrip: GLenum = 0x0005

    static let front: GLenum = 0x0404
    static let back: GLenum = 0x0405
    static let frontAndBack: GLenum = 0x0408
    static let ccw: GLenum = 0x0901

    static let cullFace: GLenum = 0x0B44
    static let depthTest: GLenum = 0x0B71
    static let blend: GLenum = 0x0BE2
    static let less: GLenum = 0x0201
    static let lessOrEqual: GLenum = 0x0203

    static let zero: GLenum = 0
    static let one: GLenum = 1
    static let srcAlpha: GLenum = 0x0302
    static let oneMinusSrcAlpha: GLenum = 0x0303
    static let dstColor: GLenum = 0x0306

    static let unsignedByte: GLenum = 0x1401
    static let unsignedShort: GLenum = 0x1403
    static let unsignedInt: GLenum = 0x1405
    static let float: GLenum = 0x1406

    static let line: GLenum = 0x1B01
    static let fill: GLenum = 0x1B02

    static let red: GLenum = 0x1903
    static let rgb: GLenum = 0x1907
    static let rgba: GLenum = 0x1908
    static let rgba8: GLenum = 0x8058
    static let rgb8: GLenum = 0x8051
    static let r8: GLenum = 0x8229
    static let rgba32f: GLenum = 0x8814

    static let texture2D: GLenum = 0x0DE1
    static let texture0: GLenum = 0x84C0
    static let textureMagFilter: GLenum = 0x2800
    static let textureMinFilter: GLenum = 0x2801
    static let textureWrapS: GLenum = 0x2802
    static let textureWrapT: GLenum = 0x2803
    static let nearest: GLenum = 0x2600
    static let linear: GLenum = 0x2601
    static let nearestMipmapNearest: GLenum = 0x2700
    static let linearMipmapNearest: GLenum = 0x2701
    static let nearestMipmapLinear: GLenum = 0x2702
    static let linearMipmapLinear: GLenum = 0x2703
    static let repeat_: GLenum = 0x2901
    static let clampToEdge: GLenum = 0x812F
    static let clampToBorder: GLenum = 0x812D
    static let mirroredRepeat: GLenum = 0x8370

    static let unpackAlignment: GLenum = 0x0CF5
    static let packAlignment: GLenum = 0x0D05

    static let arrayBuffer: GLenum = 0x8892
    static let elementArrayBuffer: GLenum = 0x8893
    static let staticDraw: GLenum = 0x88E4
    static let streamDraw: GLenum = 0x88E0

    static let fragmentShader: GLenum = 0x8B30
    static let vertexShader: GLenum = 0x8B31
    static let compileStatus: GLenum = 0x8B81
    static let linkStatus: GLenum = 0x8B82
    static let infoLogLength: GLenum = 0x8B84

    static let vendor: GLenum = 0x1F00
    static let renderer: GLenum = 0x1F01
    static let version: GLenum = 0x1F02
}

/// Looks up a GL function by name; nil when the context has none by that name.
public typealias GLProcedureLoader = (String) -> UnsafeRawPointer?

/// The GL functions used, as C function pointers.
struct GLFunctions {

    let viewport: @convention(c) (GLint, GLint, GLsizei, GLsizei) -> Void
    let clearColor: @convention(c) (GLfloat, GLfloat, GLfloat, GLfloat) -> Void
    let clear: @convention(c) (GLbitfield) -> Void
    let enable: @convention(c) (GLenum) -> Void
    let disable: @convention(c) (GLenum) -> Void
    let depthMask: @convention(c) (GLboolean) -> Void
    let depthFunc: @convention(c) (GLenum) -> Void
    let cullFace: @convention(c) (GLenum) -> Void
    let frontFace: @convention(c) (GLenum) -> Void
    let blendFunc: @convention(c) (GLenum, GLenum) -> Void
    /// Desktop GL only.
    let polygonMode: (@convention(c) (GLenum, GLenum) -> Void)?
    let getError: @convention(c) () -> GLenum
    let getString: @convention(c) (GLenum) -> UnsafePointer<UInt8>?
    let pixelStorei: @convention(c) (GLenum, GLint) -> Void
    let readPixels: @convention(c) (GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, UnsafeMutableRawPointer?) -> Void

    let genVertexArrays: @convention(c) (GLsizei, UnsafeMutablePointer<GLuint>?) -> Void
    let bindVertexArray: @convention(c) (GLuint) -> Void
    let deleteVertexArrays: @convention(c) (GLsizei, UnsafePointer<GLuint>?) -> Void
    let genBuffers: @convention(c) (GLsizei, UnsafeMutablePointer<GLuint>?) -> Void
    let bindBuffer: @convention(c) (GLenum, GLuint) -> Void
    let bufferData: @convention(c) (GLenum, GLsizeiptr, UnsafeRawPointer?, GLenum) -> Void
    let deleteBuffers: @convention(c) (GLsizei, UnsafePointer<GLuint>?) -> Void
    let enableVertexAttribArray: @convention(c) (GLuint) -> Void
    let disableVertexAttribArray: @convention(c) (GLuint) -> Void
    let vertexAttribPointer: @convention(c) (GLuint, GLint, GLenum, GLboolean, GLsizei, UnsafeRawPointer?) -> Void
    let vertexAttrib4f: @convention(c) (GLuint, GLfloat, GLfloat, GLfloat, GLfloat) -> Void

    let createShader: @convention(c) (GLenum) -> GLuint
    let shaderSource: @convention(c) (GLuint, GLsizei, UnsafePointer<UnsafePointer<CChar>?>?, UnsafePointer<GLint>?) -> Void
    let compileShader: @convention(c) (GLuint) -> Void
    let getShaderiv: @convention(c) (GLuint, GLenum, UnsafeMutablePointer<GLint>?) -> Void
    let getShaderInfoLog: @convention(c) (GLuint, GLsizei, UnsafeMutablePointer<GLsizei>?, UnsafeMutablePointer<CChar>?) -> Void
    let deleteShader: @convention(c) (GLuint) -> Void
    let createProgram: @convention(c) () -> GLuint
    let attachShader: @convention(c) (GLuint, GLuint) -> Void
    let bindAttribLocation: @convention(c) (GLuint, GLuint, UnsafePointer<CChar>?) -> Void
    let linkProgram: @convention(c) (GLuint) -> Void
    let getProgramiv: @convention(c) (GLuint, GLenum, UnsafeMutablePointer<GLint>?) -> Void
    let getProgramInfoLog: @convention(c) (GLuint, GLsizei, UnsafeMutablePointer<GLsizei>?, UnsafeMutablePointer<CChar>?) -> Void
    let useProgram: @convention(c) (GLuint) -> Void
    let deleteProgram: @convention(c) (GLuint) -> Void
    let getUniformLocation: @convention(c) (GLuint, UnsafePointer<CChar>?) -> GLint
    let uniform1i: @convention(c) (GLint, GLint) -> Void
    let uniform1f: @convention(c) (GLint, GLfloat) -> Void
    let uniform1iv: @convention(c) (GLint, GLsizei, UnsafePointer<GLint>?) -> Void
    let uniform2fv: @convention(c) (GLint, GLsizei, UnsafePointer<GLfloat>?) -> Void
    let uniform3fv: @convention(c) (GLint, GLsizei, UnsafePointer<GLfloat>?) -> Void
    let uniform4fv: @convention(c) (GLint, GLsizei, UnsafePointer<GLfloat>?) -> Void
    let uniformMatrix4fv: @convention(c) (GLint, GLsizei, GLboolean, UnsafePointer<GLfloat>?) -> Void

    let drawArrays: @convention(c) (GLenum, GLint, GLsizei) -> Void
    let drawElements: @convention(c) (GLenum, GLsizei, GLenum, UnsafeRawPointer?) -> Void

    let genTextures: @convention(c) (GLsizei, UnsafeMutablePointer<GLuint>?) -> Void
    let bindTexture: @convention(c) (GLenum, GLuint) -> Void
    let deleteTextures: @convention(c) (GLsizei, UnsafePointer<GLuint>?) -> Void
    let activeTexture: @convention(c) (GLenum) -> Void
    let texImage2D: @convention(c) (GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, UnsafeRawPointer?) -> Void
    let texParameteri: @convention(c) (GLenum, GLenum, GLint) -> Void
    let generateMipmap: @convention(c) (GLenum) -> Void

    init(loader: GLProcedureLoader) throws(GLError) {
        func load<T>(_ name: String) throws(GLError) -> T {
            guard let pointer = loader(name) else { throw .missingFunction(name) }
            return unsafeBitCast(pointer, to: T.self)
        }
        viewport = try load("glViewport")
        clearColor = try load("glClearColor")
        clear = try load("glClear")
        enable = try load("glEnable")
        disable = try load("glDisable")
        depthMask = try load("glDepthMask")
        depthFunc = try load("glDepthFunc")
        cullFace = try load("glCullFace")
        frontFace = try load("glFrontFace")
        blendFunc = try load("glBlendFunc")
        polygonMode = loader("glPolygonMode").map { unsafeBitCast($0, to: (@convention(c) (GLenum, GLenum) -> Void).self) }
        getError = try load("glGetError")
        getString = try load("glGetString")
        pixelStorei = try load("glPixelStorei")
        readPixels = try load("glReadPixels")
        genVertexArrays = try load("glGenVertexArrays")
        bindVertexArray = try load("glBindVertexArray")
        deleteVertexArrays = try load("glDeleteVertexArrays")
        genBuffers = try load("glGenBuffers")
        bindBuffer = try load("glBindBuffer")
        bufferData = try load("glBufferData")
        deleteBuffers = try load("glDeleteBuffers")
        enableVertexAttribArray = try load("glEnableVertexAttribArray")
        disableVertexAttribArray = try load("glDisableVertexAttribArray")
        vertexAttribPointer = try load("glVertexAttribPointer")
        vertexAttrib4f = try load("glVertexAttrib4f")
        createShader = try load("glCreateShader")
        shaderSource = try load("glShaderSource")
        compileShader = try load("glCompileShader")
        getShaderiv = try load("glGetShaderiv")
        getShaderInfoLog = try load("glGetShaderInfoLog")
        deleteShader = try load("glDeleteShader")
        createProgram = try load("glCreateProgram")
        attachShader = try load("glAttachShader")
        bindAttribLocation = try load("glBindAttribLocation")
        linkProgram = try load("glLinkProgram")
        getProgramiv = try load("glGetProgramiv")
        getProgramInfoLog = try load("glGetProgramInfoLog")
        useProgram = try load("glUseProgram")
        deleteProgram = try load("glDeleteProgram")
        getUniformLocation = try load("glGetUniformLocation")
        uniform1i = try load("glUniform1i")
        uniform1f = try load("glUniform1f")
        uniform1iv = try load("glUniform1iv")
        uniform2fv = try load("glUniform2fv")
        uniform3fv = try load("glUniform3fv")
        uniform4fv = try load("glUniform4fv")
        uniformMatrix4fv = try load("glUniformMatrix4fv")
        drawArrays = try load("glDrawArrays")
        drawElements = try load("glDrawElements")
        genTextures = try load("glGenTextures")
        bindTexture = try load("glBindTexture")
        deleteTextures = try load("glDeleteTextures")
        activeTexture = try load("glActiveTexture")
        texImage2D = try load("glTexImage2D")
        texParameteri = try load("glTexParameteri")
        generateMipmap = try load("glGenerateMipmap")
    }

    func string(_ name: GLenum) -> String? {
        getString(name).map { String(cString: $0) }
    }
}

/// Why OpenGL couldn't be set up or draw.
public enum GLError: Error, Hashable, Sendable {
    /// The context has no function by the name.
    case missingFunction(String)
    /// A shader didn't compile, with the compiler's log.
    case shaderCompilation(String)
    /// The program didn't link, with the linker's log.
    case programLink(String)
}
