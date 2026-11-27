import SceneCore

/// Draws recorded frames with OpenGL 3.3 Core or OpenGL ES 3.0 in whatever context is current.
///
/// Meshes with a key are kept in vertex arrays and buffers until their revision changes or they go unused for a
/// while; immediate meshes are uploaded into a scratch buffer each time they are drawn. The renderer knows nothing
/// of windows: any host that makes a context current and can look up its functions can use it.
public final class OpenGLRenderer {

    /// Draws polygons as outlines, with an indexed-line fallback on OpenGL ES.
    public var isWireframe = false

    /// Resolves a texture that isn't already an image in memory, such as a path; nil draws it untextured.
    public var textureLoader: ((TextureSource) -> ImageBuffer?)?

    /// The context's vendor, renderer and version strings.
    public let vendor: String
    public let renderer: String
    public let version: String

    /// Whether the context is OpenGL ES.
    public let isES: Bool

    private let gl: GLFunctions
    private let program: GLuint
    private var uniformLocations: [String: GLint] = [:]
    private var meshes: [UInt64: MeshResource] = [:]
    private var scratch: MeshResource?
    private struct TextureKey: Hashable {
        var source: TextureSource
        var sampler: TextureSampler
    }
    private var textures: [TextureKey: TextureResource] = [:]
    /// Bound when a draw has no texture, so the sampler always reads a complete one.
    private var whiteTexture: GLuint = 0
    private var frameNumber = 0

    /// How many frames a mesh or texture may go undrawn before its GPU memory is freed.
    private let evictionAge = 120

    public init(loader: GLProcedureLoader, isES: Bool) throws(GLError) {
        let gl = try GLFunctions(loader: loader)
        self.gl = gl
        self.isES = isES
        self.vendor = gl.string(GLConstant.vendor) ?? ""
        self.renderer = gl.string(GLConstant.renderer) ?? ""
        self.version = gl.string(GLConstant.version) ?? ""
        self.program = try Self.makeProgram(gl, isES: isES)
        gl.genTextures(1, &whiteTexture)
        gl.bindTexture(GLConstant.texture2D, whiteTexture)
        let white: [UInt8] = [255, 255, 255, 255]
        white.withUnsafeBytes {
            gl.texImage2D(GLConstant.texture2D, 0, GLint(bitPattern: GLConstant.rgba8), 1, 1, 0, GLConstant.rgba, GLConstant.unsignedByte, $0.baseAddress)
        }
        gl.texParameteri(GLConstant.texture2D, GLConstant.textureMinFilter, GLint(bitPattern: GLConstant.nearest))
        gl.texParameteri(GLConstant.texture2D, GLConstant.textureMagFilter, GLint(bitPattern: GLConstant.nearest))
    }

    /// Drops cached images after an asset or one of its texture files changes.
    public func invalidateTextures() {
        for texture in textures.values {
            withUnsafePointer(to: texture.name) { gl.deleteTextures(1, $0) }
        }
        textures.removeAll()
    }

    /// Frees the GL objects; call while the context is current, before it is destroyed.
    public func releaseResources() {
        for mesh in meshes.values { delete(mesh) }
        meshes.removeAll()
        if let scratch { delete(scratch) }
        scratch = nil
        for texture in textures.values {
            withUnsafePointer(to: texture.name) { gl.deleteTextures(1, $0) }
        }
        textures.removeAll()
        gl.deleteTextures(1, &whiteTexture)
        gl.deleteProgram(program)
    }

    // MARK: Drawing

    /// Draws a frame's commands into the current framebuffer.
    public func draw(_ frame: RecordedCommandBuffer) {
        frameNumber += 1
        let target = frame.target
        gl.viewport(0, 0, GLsizei(target.width), GLsizei(target.height))
        gl.depthMask(GLConstant.true_)
        if let clear = target.clearColor {
            // The clear colour is linear, the framebuffer sRGB.
            func encode(_ c: Float) -> Float { Elementary.pow(max(c, 0), 1 / 2.2) }
            gl.clearColor(encode(clear.x), encode(clear.y), encode(clear.z), clear.w)
            gl.clear(GLConstant.colorBufferBit | GLConstant.depthBufferBit)
        } else {
            gl.clear(GLConstant.depthBufferBit)
        }
        gl.useProgram(program)
        gl.frontFace(GLConstant.ccw)
        gl.depthFunc(GLConstant.lessOrEqual)
        if let polygonMode = gl.polygonMode {
            polygonMode(GLConstant.frontAndBack, isWireframe ? GLConstant.line : GLConstant.fill)
        }
        uniform("u_diffuseTexture") { gl.uniform1i($0, 0) }

        var camera = CameraUniforms(viewMatrix: .identity, projectionMatrix: .identity)
        for command in frame.commands {
            switch command {
            case .setCamera(let uniforms):
                camera = uniforms
                setMatrix("u_viewProjection", uniforms.viewProjectionMatrix)
                setVector3("u_cameraPosition", [uniforms.position])
            case .setLights(let lights):
                setLights(lights)
            case .draw(let call):
                draw(call, camera: camera)
            }
        }
        gl.bindVertexArray(0)
        evictUnused()
    }

    private func draw(_ call: DrawCall, camera: CameraUniforms) {
        var call = call
        let wire = isWireframe && call.material.readsFromDepthBuffer
        if let polygonMode = gl.polygonMode {
            polygonMode(GLConstant.frontAndBack, wire ? GLConstant.line : GLConstant.fill)
        } else if wire, call.submesh.primitive == .triangles || call.submesh.primitive == .triangleStrip {
            let triangles = call.mesh.triangles(in: call.submesh)
            let edges = triangles.flatMap { [$0.x, $0.y, $0.y, $0.z, $0.z, $0.x] }
            call.mesh.indices = IndexBuffer(edges)
            call.mesh.submeshes = [Submesh(primitive: .lines, range: 0..<edges.count, materialIndex: 0)]
            call.submeshIndex = 0
            call.meshKey = nil
        }
        let resource = meshResource(for: call)
        gl.bindVertexArray(resource.vertexArray)
        // Streams the mesh lacks read as constants, which aren't part of a vertex array's state.
        if !resource.hasNormals { gl.vertexAttrib4f(GLShaders.normalLocation, 0, 0, 1, 0) }
        if !resource.hasTextureCoordinates { gl.vertexAttrib4f(GLShaders.textureCoordinateLocation, 0, 0, 0, 0) }
        if !resource.hasTextureCoordinates1 { gl.vertexAttrib4f(GLShaders.textureCoordinate1Location, 0, 0, 0, 0) }
        if !resource.hasTangents { gl.vertexAttrib4f(GLShaders.tangentLocation, 0, 0, 0, 1) }
        if !resource.hasColors { gl.vertexAttrib4f(GLShaders.colorLocation, 1, 1, 1, 1) }

        setMatrix("u_model", call.worldTransform)
        setMatrix("u_normalMatrix", call.worldTransform.normalMatrix)
        setMaterial(call.material, opacity: call.opacity)

        let submesh = call.submesh
        let mode = Self.mode(submesh.primitive)
        let count = GLsizei(submesh.range.count)
        guard count > 0 else { return }
        if let indexType = resource.indexType {
            let size = indexType == GLConstant.unsignedShort ? 2 : 4
            gl.drawElements(mode, count, indexType, UnsafeRawPointer(bitPattern: submesh.range.lowerBound * size))
        } else {
            gl.drawArrays(mode, GLint(submesh.range.lowerBound), count)
        }
    }

    private static func mode(_ primitive: PrimitiveType) -> GLenum {
        switch primitive {
        case .triangles: GLConstant.triangles
        case .triangleStrip: GLConstant.triangleStrip
        case .lines: GLConstant.lines
        case .lineStrip: GLConstant.lineStrip
        case .points: GLConstant.points
        }
    }

    // MARK: Materials and lights

    private func setMaterial(_ material: MaterialDescriptor, opacity: Float) {
        let model: GLint = switch material.lightingModel {
        case .physicallyBased: 0
        case .blinn: 1
        case .phong: 2
        case .lambert: 3
        case .unlit: 4
        }
        uniform("u_lightingModel") { gl.uniform1i($0, model) }

        var diffuse = SIMD4<Float>(1, 1, 1, 1)
        var texture: TextureResource?
        switch material.diffuse.contents {
        case .color, .scalar:
            diffuse = material.diffuse.color ?? diffuse
        case .texture(let source):
            texture = textureResource(for: source, sampler: material.diffuse.sampler)
        case .none:
            break
        }
        diffuse = SIMD4(diffuse.xyz * material.diffuse.intensity, diffuse.w) * material.diffuseFactor
        setVector4("u_diffuse", diffuse)
        uniform("u_hasDiffuseTexture") { gl.uniform1i($0, texture == nil ? 0 : 1) }
        gl.activeTexture(GLConstant.texture0)
        gl.bindTexture(GLConstant.texture2D, texture?.name ?? whiteTexture)
        setMatrix("u_textureTransform", material.diffuse.contentsTransform)
        uniform("u_diffuseChannel") { gl.uniform1i($0, GLint(material.diffuse.mappingChannel)) }
        func bind(_ property: MaterialProperty, unit: GLint, name: String) {
            gl.activeTexture(GLConstant.texture0 + GLenum(unit))
            var texture: TextureResource?
            if case .texture(let source) = property.contents {
                texture = textureResource(for: source, sampler: property.sampler)
            }
            gl.bindTexture(GLConstant.texture2D, texture?.name ?? whiteTexture)
            uniform("u_has" + name + "Texture") { gl.uniform1i($0, texture == nil ? 0 : 1) }
            let lower = name.prefix(1).lowercased() + name.dropFirst()
            uniform("u_" + lower + "Texture") { gl.uniform1i($0, unit) }
            uniform("u_" + lower + "Channel") { gl.uniform1i($0, GLint(property.mappingChannel)) }
        }
        bind(material.metalness, unit: 1, name: "MetallicRoughness")
        bind(material.normal, unit: 2, name: "Normal")
        bind(material.ambientOcclusion, unit: 3, name: "Occlusion")
        bind(material.emission, unit: 4, name: "Emission")
        gl.activeTexture(GLConstant.texture0)
        uniform("u_normalScale") { gl.uniform1f($0, material.normal.intensity) }
        uniform("u_occlusionStrength") { gl.uniform1f($0, material.ambientOcclusion.intensity) }
        let alphaMode: GLint
        let cutoff: Float
        switch material.alphaMode {
        case .legacy, .blend: alphaMode = 0; cutoff = 0
        case .opaque: alphaMode = 1; cutoff = 0
        case .mask(let value): alphaMode = 2; cutoff = value
        }
        uniform("u_alphaMode") { gl.uniform1i($0, alphaMode) }
        uniform("u_alphaCutoff") { gl.uniform1f($0, cutoff) }

        func rgb(_ property: MaterialProperty) -> SIMD3<Float> {
            (property.color?.xyz ?? .zero) * property.intensity
        }
        setVector3("u_ambient", [rgb(material.ambient)])
        setVector3("u_specular", [rgb(material.specular)])
        let emission: SIMD3<Float>
        if case .texture = material.emission.contents { emission = material.emissionFactor }
        else { emission = rgb(material.emission) * material.emissionFactor }
        setVector3("u_emission", [emission])
        uniform("u_shininess") { gl.uniform1f($0, material.shininess) }
        uniform("u_metalness") { gl.uniform1f($0, (material.metalness.color?.x ?? 1) * material.metalnessFactor) }
        uniform("u_roughness") { gl.uniform1f($0, (material.roughness.color?.x ?? 1) * material.roughnessFactor) }
        uniform("u_opacity") { gl.uniform1f($0, material.transparency * opacity) }
        uniform("u_isDoubleSided") { gl.uniform1i($0, material.isDoubleSided ? 1 : 0) }

        if material.isDoubleSided {
            gl.disable(GLConstant.cullFace)
        } else {
            gl.enable(GLConstant.cullFace)
            gl.cullFace(material.cullMode == .back ? GLConstant.back : GLConstant.front)
        }
        if material.readsFromDepthBuffer {
            gl.enable(GLConstant.depthTest)
        } else {
            gl.disable(GLConstant.depthTest)
        }
        gl.depthMask(material.writesToDepthBuffer ? GLConstant.true_ : GLConstant.false_)
        if material.isTranslucent || opacity < 1 || material.blendMode == .add || material.blendMode == .multiply {
            gl.enable(GLConstant.blend)
            switch material.blendMode {
            case .alpha: gl.blendFunc(GLConstant.srcAlpha, GLConstant.oneMinusSrcAlpha)
            case .add: gl.blendFunc(GLConstant.srcAlpha, GLConstant.one)
            case .multiply: gl.blendFunc(GLConstant.dstColor, GLConstant.zero)
            case .replace: gl.disable(GLConstant.blend)
            }
        } else {
            gl.disable(GLConstant.blend)
        }
    }

    private func setLights(_ lights: [LightInstance]) {
        let lights = Array(lights.prefix(GLShaders.maxLights))
        uniform("u_lightCount") { gl.uniform1i($0, GLint(lights.count)) }
        guard !lights.isEmpty else { return }
        let types: [GLint] = lights.map {
            switch $0.light.kind {
            case .ambient: 0
            case .directional: 1
            case .omni: 2
            case .spot: 3
            }
        }
        uniform("u_lightType") { location in types.withUnsafeBufferPointer { gl.uniform1iv(location, GLsizei(types.count), $0.baseAddress) } }
        setVector3("u_lightColor", lights.map(\.light.radiance))
        setVector3("u_lightPosition", lights.map(\.position))
        setVector3("u_lightDirection", lights.map(\.direction))
        setVector3("u_lightAttenuation", lights.map {
            SIMD3($0.light.attenuationStartDistance, $0.light.attenuationEndDistance, $0.light.attenuationFalloffExponent)
        })
        let spots = lights.flatMap {
            [Elementary.cos(radians(degrees: $0.light.spotInnerAngle) / 2), Elementary.cos(radians(degrees: $0.light.spotOuterAngle) / 2)]
        }
        uniform("u_lightSpot") { location in spots.withUnsafeBufferPointer { gl.uniform2fv(location, GLsizei(lights.count), $0.baseAddress) } }
    }

    // MARK: Uniforms

    private func uniform(_ name: String, _ set: (GLint) -> Void) {
        let location: GLint
        if let known = uniformLocations[name] {
            location = known
        } else {
            location = gl.getUniformLocation(program, name)
            uniformLocations[name] = location
        }
        // A uniform the compiler optimized away has no location.
        if location >= 0 { set(location) }
    }

    private func setMatrix(_ name: String, _ matrix: Matrix4x4) {
        let elements = matrix.columnMajorElements
        uniform(name) { location in elements.withUnsafeBufferPointer { gl.uniformMatrix4fv(location, 1, GLConstant.false_, $0.baseAddress) } }
    }

    private func setVector3(_ name: String, _ vectors: [SIMD3<Float>]) {
        let elements = vectors.flatMap { [$0.x, $0.y, $0.z] }
        uniform(name) { location in elements.withUnsafeBufferPointer { gl.uniform3fv(location, GLsizei(vectors.count), $0.baseAddress) } }
    }

    private func setVector4(_ name: String, _ vector: SIMD4<Float>) {
        let elements = [vector.x, vector.y, vector.z, vector.w]
        uniform(name) { location in elements.withUnsafeBufferPointer { gl.uniform4fv(location, 1, $0.baseAddress) } }
    }

    // MARK: Meshes

    private final class MeshResource {
        var revision: UInt64 = 0
        var vertexArray: GLuint = 0
        var vertexBuffer: GLuint = 0
        var indexBuffer: GLuint = 0
        var indexType: GLenum?
        var hasNormals = false
        var hasTextureCoordinates = false
        var hasColors = false
        var hasTextureCoordinates1 = false
        var hasTangents = false
        var lastUsed = 0
    }

    private func meshResource(for call: DrawCall) -> MeshResource {
        guard let key = call.meshKey else {
            // Immediate: the scratch buffers, filled again.
            let resource = scratch ?? makeMeshResource()
            scratch = resource
            upload(call.mesh, into: resource, usage: GLConstant.streamDraw)
            return resource
        }
        if let resource = meshes[key.id], resource.revision == key.revision {
            resource.lastUsed = frameNumber
            return resource
        }
        let resource = meshes[key.id] ?? makeMeshResource()
        upload(call.mesh, into: resource, usage: GLConstant.staticDraw)
        resource.revision = key.revision
        resource.lastUsed = frameNumber
        meshes[key.id] = resource
        return resource
    }

    private func makeMeshResource() -> MeshResource {
        let resource = MeshResource()
        gl.genVertexArrays(1, &resource.vertexArray)
        gl.genBuffers(1, &resource.vertexBuffer)
        gl.genBuffers(1, &resource.indexBuffer)
        return resource
    }

    private func upload(_ mesh: MeshBuffer, into resource: MeshResource, usage: GLenum) {
        let vertices = mesh.interleaved()
        gl.bindVertexArray(resource.vertexArray)
        gl.bindBuffer(GLConstant.arrayBuffer, resource.vertexBuffer)
        vertices.data.withUnsafeBytes { gl.bufferData(GLConstant.arrayBuffer, $0.count, $0.baseAddress, usage) }

        let stride = GLsizei(vertices.stride * MemoryLayout<Float>.size)
        var enabled: Set<GLuint> = []
        for attribute in vertices.attributes {
            let location: GLuint
            switch attribute.semantic {
            case .position: location = GLShaders.positionLocation
            case .normal: location = GLShaders.normalLocation
            case .textureCoordinate(0): location = GLShaders.textureCoordinateLocation
            case .tangent: location = GLShaders.tangentLocation
            case .color: location = GLShaders.colorLocation
            case .textureCoordinate(1): location = GLShaders.textureCoordinate1Location
            default: continue
            }
            gl.enableVertexAttribArray(location)
            let offset = UnsafeRawPointer(bitPattern: attribute.offset * MemoryLayout<Float>.size)
            gl.vertexAttribPointer(location, GLint(attribute.componentCount), GLConstant.float, GLConstant.false_, stride, offset)
            enabled.insert(location)
        }
        for location in [GLShaders.positionLocation, GLShaders.normalLocation, GLShaders.textureCoordinateLocation, GLShaders.colorLocation, GLShaders.textureCoordinate1Location, GLShaders.tangentLocation]
        where !enabled.contains(location) {
            gl.disableVertexAttribArray(location)
        }
        resource.hasNormals = enabled.contains(GLShaders.normalLocation)
        resource.hasTextureCoordinates = enabled.contains(GLShaders.textureCoordinateLocation)
        resource.hasTangents = enabled.contains(GLShaders.tangentLocation)
        resource.hasColors = enabled.contains(GLShaders.colorLocation)
        resource.hasTextureCoordinates1 = enabled.contains(GLShaders.textureCoordinate1Location)

        gl.bindBuffer(GLConstant.elementArrayBuffer, resource.indexBuffer)
        switch mesh.indices {
        case .uint16(let indices)?:
            indices.withUnsafeBytes { gl.bufferData(GLConstant.elementArrayBuffer, $0.count, $0.baseAddress, usage) }
            resource.indexType = GLConstant.unsignedShort
        case .uint32(let indices)?:
            indices.withUnsafeBytes { gl.bufferData(GLConstant.elementArrayBuffer, $0.count, $0.baseAddress, usage) }
            resource.indexType = GLConstant.unsignedInt
        case nil:
            gl.bufferData(GLConstant.elementArrayBuffer, 0, nil, usage)
            resource.indexType = nil
        }
    }

    private func delete(_ resource: MeshResource) {
        gl.deleteVertexArrays(1, &resource.vertexArray)
        gl.deleteBuffers(1, &resource.vertexBuffer)
        gl.deleteBuffers(1, &resource.indexBuffer)
    }

    // MARK: Textures

    private struct TextureResource {
        var name: GLuint
        var sampler: TextureSampler
        var lastUsed: Int
    }

    private func textureResource(for source: TextureSource, sampler: TextureSampler) -> TextureResource? {
        let key = TextureKey(source: source, sampler: sampler)
        if var known = textures[key] {
            if known.sampler != sampler {
                gl.bindTexture(GLConstant.texture2D, known.name)
                applySampler(sampler, hasMipmaps: true)
                known.sampler = sampler
            }
            known.lastUsed = frameNumber
            textures[key] = known
            return known
        }
        let image: ImageBuffer
        if case .image(let inMemory) = source {
            image = inMemory
        } else if let loaded = textureLoader?(source) {
            image = loaded
        } else {
            return nil
        }
        var name: GLuint = 0
        gl.genTextures(1, &name)
        gl.bindTexture(GLConstant.texture2D, name)
        gl.pixelStorei(GLConstant.unpackAlignment, 1)
        let (internalFormat, format, type, pixels) = Self.uploadFormat(image)
        pixels.withUnsafeBytes {
            gl.texImage2D(GLConstant.texture2D, 0, GLint(bitPattern: internalFormat), GLsizei(image.width), GLsizei(image.height), 0, format, type, $0.baseAddress)
        }
        gl.generateMipmap(GLConstant.texture2D)
        applySampler(sampler, hasMipmaps: true)
        let resource = TextureResource(name: name, sampler: sampler, lastUsed: frameNumber)
        textures[key] = resource
        return resource
    }

    private func applySampler(_ sampler: TextureSampler, hasMipmaps: Bool) {
        func wrap(_ mode: TextureWrapMode) -> GLint {
            let value: GLenum = switch mode {
            case .clamp: GLConstant.clampToEdge
            // ES 3.0 has no border colour; clamping to the edge is the nearest.
            case .clampToBorder: isES ? GLConstant.clampToEdge : GLConstant.clampToBorder
            case .repeat: GLConstant.repeat_
            case .mirror: GLConstant.mirroredRepeat
            }
            return GLint(bitPattern: value)
        }
        let nearest = sampler.minificationFilter == .nearest
        let minification: GLenum = switch (hasMipmaps ? sampler.mipFilter : .none) {
        case .none: nearest ? GLConstant.nearest : GLConstant.linear
        case .nearest: nearest ? GLConstant.nearestMipmapNearest : GLConstant.linearMipmapNearest
        case .linear: nearest ? GLConstant.nearestMipmapLinear : GLConstant.linearMipmapLinear
        }
        let magnification = sampler.magnificationFilter == .nearest ? GLConstant.nearest : GLConstant.linear
        gl.texParameteri(GLConstant.texture2D, GLConstant.textureWrapS, wrap(sampler.wrapS))
        gl.texParameteri(GLConstant.texture2D, GLConstant.textureWrapT, wrap(sampler.wrapT))
        gl.texParameteri(GLConstant.texture2D, GLConstant.textureMinFilter, GLint(bitPattern: minification))
        gl.texParameteri(GLConstant.texture2D, GLConstant.textureMagFilter, GLint(bitPattern: magnification))
    }

    /// The image's pixels as GL takes them: tightly packed rows, from the top, which texture coordinates
    /// with 0, 0 at the top left then read the right way up.
    private static func uploadFormat(_ image: ImageBuffer) -> (internal: GLenum, format: GLenum, type: GLenum, pixels: [UInt8]) {
        let width = image.width, height = image.height
        let bpp = image.format.bytesPerPixel
        func packed() -> [UInt8] {
            guard image.bytesPerRow != width * bpp else { return image.pixels }
            var rows = [UInt8]()
            rows.reserveCapacity(width * bpp * height)
            for row in 0..<height {
                let start = row * image.bytesPerRow
                rows.append(contentsOf: image.pixels[start ..< start + width * bpp])
            }
            return rows
        }
        func toRGBA(_ convert: (ArraySlice<UInt8>) -> [UInt8]) -> [UInt8] {
            let source = packed()
            var rgba = [UInt8]()
            rgba.reserveCapacity(width * height * 4)
            for pixel in 0..<(width * height) {
                rgba.append(contentsOf: convert(source[pixel * bpp ..< (pixel + 1) * bpp]))
            }
            return rgba
        }
        switch image.format {
        case .rgba8:
            return (GLConstant.rgba8, GLConstant.rgba, GLConstant.unsignedByte, packed())
        case .rgb8:
            return (GLConstant.rgb8, GLConstant.rgb, GLConstant.unsignedByte, packed())
        case .r8:
            return (GLConstant.r8, GLConstant.red, GLConstant.unsignedByte, packed())
        case .rgba32Float:
            return (GLConstant.rgba32f, GLConstant.rgba, GLConstant.float, packed())
        case .bgra8:
            return (GLConstant.rgba8, GLConstant.rgba, GLConstant.unsignedByte, toRGBA { p in
                [p[p.startIndex + 2], p[p.startIndex + 1], p[p.startIndex], p[p.startIndex + 3]]
            })
        case .argb8:
            return (GLConstant.rgba8, GLConstant.rgba, GLConstant.unsignedByte, toRGBA { p in
                [p[p.startIndex + 1], p[p.startIndex + 2], p[p.startIndex + 3], p[p.startIndex]]
            })
        case .rgb555:
            // Big-endian, as QuickDraw 3D's: x rrrrr ggggg bbbbb.
            return (GLConstant.rgba8, GLConstant.rgba, GLConstant.unsignedByte, toRGBA { p in
                let value = UInt16(p[p.startIndex]) << 8 | UInt16(p[p.startIndex + 1])
                func expand(_ c: UInt16) -> UInt8 { UInt8((c & 0x1F) << 3 | (c & 0x1F) >> 2) }
                return [expand(value >> 10), expand(value >> 5), expand(value), 255]
            })
        }
    }

    // MARK: Housekeeping

    private func evictUnused() {
        guard frameNumber % evictionAge == 0 else { return }
        for (id, mesh) in meshes where frameNumber - mesh.lastUsed > evictionAge {
            delete(mesh)
            meshes[id] = nil
        }
        for (source, texture) in textures where frameNumber - texture.lastUsed > evictionAge {
            withUnsafePointer(to: texture.name) { gl.deleteTextures(1, $0) }
            textures[source] = nil
        }
    }

    // MARK: Reading back

    /// The framebuffer's pixels, rows from the top: for screenshots and tests, not every frame.
    public func readPixels(width: Int, height: Int) -> ImageBuffer {
        var bottomUp = [UInt8](repeating: 0, count: width * height * 4)
        gl.pixelStorei(GLConstant.packAlignment, 1)
        bottomUp.withUnsafeMutableBytes {
            gl.readPixels(0, 0, GLsizei(width), GLsizei(height), GLConstant.rgba, GLConstant.unsignedByte, $0.baseAddress)
        }
        var pixels = [UInt8]()
        pixels.reserveCapacity(bottomUp.count)
        let rowBytes = width * 4
        for row in (0..<height).reversed() {
            pixels.append(contentsOf: bottomUp[row * rowBytes ..< (row + 1) * rowBytes])
        }
        return ImageBuffer(width: width, height: height, format: .rgba8, pixels: pixels)
    }

    // MARK: Program

    private static func makeProgram(_ gl: GLFunctions, isES: Bool) throws(GLError) -> GLuint {
        let header = GLShaders.header(isES: isES)
        let vertex = try compile(gl, GLConstant.vertexShader, header + GLShaders.vertex)
        let fragment: GLuint
        do {
            fragment = try compile(gl, GLConstant.fragmentShader, header + GLShaders.fragment)
        } catch {
            gl.deleteShader(vertex)
            throw error
        }
        let program = gl.createProgram()
        gl.attachShader(program, vertex)
        gl.attachShader(program, fragment)
        gl.bindAttribLocation(program, GLShaders.positionLocation, "a_position")
        gl.bindAttribLocation(program, GLShaders.normalLocation, "a_normal")
        gl.bindAttribLocation(program, GLShaders.textureCoordinateLocation, "a_textureCoordinate")
        gl.bindAttribLocation(program, GLShaders.tangentLocation, "a_tangent")
        gl.bindAttribLocation(program, GLShaders.colorLocation, "a_color")
        gl.bindAttribLocation(program, GLShaders.textureCoordinate1Location, "a_textureCoordinate1")
        gl.linkProgram(program)
        gl.deleteShader(vertex)
        gl.deleteShader(fragment)
        var status: GLint = 0
        gl.getProgramiv(program, GLConstant.linkStatus, &status)
        guard status != 0 else {
            let log = infoLog { gl.getProgramiv(program, GLConstant.infoLogLength, $0) } read: { gl.getProgramInfoLog(program, $0, nil, $1) }
            gl.deleteProgram(program)
            throw .programLink(log)
        }
        return program
    }

    private static func compile(_ gl: GLFunctions, _ type: GLenum, _ source: String) throws(GLError) -> GLuint {
        let shader = gl.createShader(type)
        source.withCString { pointer in
            var string: UnsafePointer<CChar>? = pointer
            gl.shaderSource(shader, 1, &string, nil)
        }
        gl.compileShader(shader)
        var status: GLint = 0
        gl.getShaderiv(shader, GLConstant.compileStatus, &status)
        guard status != 0 else {
            let log = infoLog { gl.getShaderiv(shader, GLConstant.infoLogLength, $0) } read: { gl.getShaderInfoLog(shader, $0, nil, $1) }
            gl.deleteShader(shader)
            throw .shaderCompilation(log)
        }
        return shader
    }

    private static func infoLog(
        length: (UnsafeMutablePointer<GLint>) -> Void,
        read: (GLsizei, UnsafeMutablePointer<CChar>) -> Void
    ) -> String {
        var count: GLint = 0
        length(&count)
        guard count > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: Int(count))
        buffer.withUnsafeMutableBufferPointer { read(count, $0.baseAddress!) }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
