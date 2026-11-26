import SceneCore

/// Draws a scene with any `RenderBackend`: an OpenGL or Vulkan framebuffer, a Metal texture, or nothing at all.
///
/// Each frame it finds the point of view, gathers the lights, walks the tree for what is visible and inside the
/// camera's frustum, and encodes a draw for each submesh of each geometry: opaque ones first, then translucent
/// ones from back to front.
public final class SceneRenderer<Backend: RenderBackend> {

    public let backend: Backend

    public var scene: Scene?

    /// The node seen from; the scene's first camera when nil, or a default one framing the scene.
    public var pointOfView: Node?

    /// Lights a scene that has none, from the point of view.
    public var autoenablesDefaultLighting = false

    /// Skips geometry wholly outside the camera's view.
    public var isFrustumCullingEnabled = true

    /// Only nodes whose category bit mask shares a bit with this are drawn.
    public var categoryBitMask = Int(bitPattern: UInt(Int.max) * 2 + 1)

    public init(backend: Backend, scene: Scene? = nil) {
        self.backend = backend
        self.scene = scene
    }

    /// Moves the scene on by the time since the last frame.
    public func update(by delta: Duration) {
        scene?.update(by: delta)
    }

    /// Draws a frame of the scene.
    public func render(target: RenderTargetDescriptor) throws(RenderError) {
        var commands = try backend.beginFrame(target: target)
        if let scene {
            encode(scene, target: target, into: &commands)
        }
        try backend.endFrame(commands)
    }

    /// Encodes a frame of the scene into a command buffer, for a caller that adds commands of its own.
    public func encode(_ scene: Scene, target: RenderTargetDescriptor, into commands: inout Backend.CommandBuffer) {
        let camera = cameraUniforms(for: scene, aspectRatio: target.aspectRatio)
        commands.setCamera(camera)
        commands.setLights(lights(in: scene, camera: camera))
        let frustum = isFrustumCullingEnabled ? camera.frustum : nil
        var opaque: [DrawCall] = [], translucent: [(depth: Float, call: DrawCall)] = []
        collect(scene.rootNode, parentWorld: .identity, opacity: 1, frustum: frustum) { call in
            if call.material.isTranslucent || call.opacity < 1 {
                let center = call.worldTransform.transformPoint(call.mesh.bounds.center)
                translucent.append(((camera.viewMatrix.transformPoint(center)).z, call))
            } else {
                opaque.append(call)
            }
        }
        for call in opaque {
            commands.draw(call)
        }
        // Further first: view space looks down -z.
        for item in translucent.sorted(by: { $0.depth < $1.depth }) {
            commands.draw(item.call)
        }
    }

    // MARK: Camera

    /// The view and projection the scene is seen with.
    public func cameraUniforms(for scene: Scene, aspectRatio: Float) -> CameraUniforms {
        if let node = pointOfView ?? scene.firstCameraNode {
            let world = node.worldTransform
            let lens = node.camera?.descriptor ?? CameraDescriptor()
            return CameraUniforms(viewMatrix: world.inverse ?? .identity, projectionMatrix: lens.projectionMatrix(aspectRatio: aspectRatio))
        }
        // No camera: one on the +z axis, far enough back to see the whole scene.
        let bounds = scene.rootNode.hierarchyBoundingBox.transformed(by: scene.rootNode.transform)
        let sphere = bounds.boundingSphere
        var lens = CameraDescriptor()
        let radius = max(sphere.radius, 1)
        let distance = radius / Elementary.tan(radians(degrees: lens.fieldOfView) / 2) + radius
        lens.zNear = max(distance - radius * 2, 0.01)
        lens.zFar = distance + radius * 2
        let eye = sphere.center + SIMD3(0, 0, distance)
        return CameraUniforms(
            viewMatrix: .lookAt(eye: eye, target: sphere.center, up: SIMD3(0, 1, 0)),
            projectionMatrix: lens.projectionMatrix(aspectRatio: aspectRatio)
        )
    }

    // MARK: Lights

    private func lights(in scene: Scene, camera: CameraUniforms) -> [LightInstance] {
        var lights: [LightInstance] = []
        scene.rootNode.enumerateHierarchy { node, _ in
            if let light = node.light {
                lights.append(LightInstance(light: light.descriptor, worldTransform: node.worldTransform))
            }
        }
        if lights.isEmpty, autoenablesDefaultLighting {
            // An omni light at the eye, and a little ambient light.
            let eye = camera.viewMatrix.inverse ?? .identity
            lights.append(LightInstance(light: LightDescriptor(kind: .omni), worldTransform: eye))
            lights.append(LightInstance(light: LightDescriptor(kind: .ambient, intensity: 100), worldTransform: .identity))
        }
        return lights
    }

    // MARK: Geometry

    private func collect(
        _ node: Node,
        parentWorld: Matrix4x4,
        opacity parentOpacity: Float,
        frustum: Frustum?,
        _ emit: (DrawCall) -> Void
    ) {
        let visibility = node.visibility
        guard !visibility.isHidden else { return }
        let opacity = parentOpacity * visibility.opacity
        guard opacity > 0 else { return }
        let world = parentWorld * node.transform
        if let geometry = node.geometry, visibility.categoryBitMask & categoryBitMask != 0 {
            let mesh = geometry.mesh
            let visible = frustum.map { $0.intersects(mesh.bounds.transformed(by: world)) } ?? true
            if visible {
                for index in mesh.submeshes.indices where !mesh.submeshes[index].range.isEmpty {
                    emit(DrawCall(
                        meshKey: geometry.key,
                        mesh: mesh,
                        submeshIndex: index,
                        material: geometry.material(forSubmesh: index).descriptor,
                        worldTransform: world,
                        opacity: opacity
                    ))
                }
            }
        }
        for child in node.children {
            collect(child, parentWorld: world, opacity: opacity, frustum: frustum, emit)
        }
    }
}
