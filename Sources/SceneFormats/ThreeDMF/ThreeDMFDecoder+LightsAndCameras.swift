// Ported from Quesa's light, camera and style readers (E3Light.cpp, E3Camera.cpp, E3FFR_3DMF.cpp).
// Copyright (c) 1999-2021, Quesa Developers. All rights reserved.
// Licensed under the BSD 3-Clause License; see LICENSE-Quesa.

import SceneCore
import SceneGraph

extension ThreeDMFDecoder {

    // MARK: Lights

    /// A light as a node: an ambient light; a directional light's direction and whether it casts shadows; a point
    /// light's location, attenuation and shadows; a spot light's location, direction, shadows, attenuation, hot and
    /// outer half-angles and fall-off. A `LightData` child says whether it's on, how bright, and its colour; one
    /// that's off isn't made. Attenuation by inverse distance isn't kept: lights reach as far as they shine.
    func light(_ object: MetafileObject, state: State) throws(SceneFormatError) -> Node? {
        var r = object.reader()
        var descriptor = LightDescriptor()
        var location = SIMD3<Float>.zero
        var direction = SIMD3<Float>(0, 0, -1)
        let attenuations: [String: UInt32] = ["none": 0, "inverse": 1, "inversesquare": 2]
        switch object.type {
        case .ambientLight:
            descriptor.kind = .ambient
        case .directionalLight:
            descriptor.kind = .directional
            if !r.isAtEnd { direction = try r.vector3() }
            if !r.isAtEnd { descriptor.castsShadow = try r.boolean() }
        case .pointLight:
            descriptor.kind = .omni
            if !r.isAtEnd { location = try r.vector3() }
            if !r.isAtEnd { _ = try r.enumerated(attenuations) }
            if !r.isAtEnd { descriptor.castsShadow = try r.boolean() }
        default:
            descriptor.kind = .spot
            if !r.isAtEnd { location = try r.vector3() }
            if !r.isAtEnd { direction = try r.vector3() }
            if !r.isAtEnd { descriptor.castsShadow = try r.boolean() }
            if !r.isAtEnd { _ = try r.enumerated(attenuations) }
            // Half-angles in radians; ours are whole cones in degrees.
            if !r.isAtEnd { descriptor.spotInnerAngle = degrees(radians: 2 * (try r.float32())) }
            if !r.isAtEnd { descriptor.spotOuterAngle = degrees(radians: 2 * (try r.float32())) }
        }
        if let data = object.children.first(where: { $0.type == .lightData }) {
            var d = data.reader()
            let isOn = try d.boolean()
            guard isOn else { return nil }
            let brightness = try d.float32()
            descriptor.intensity = 1000 * brightness
            descriptor.color = try d.vector3()
        }
        let node = Node(name: Self.name(in: object.children))
        node.light = Light(descriptor)
        // Lights shine down their node's -z.
        var local = Matrix4x4(translation: location)
        if direction.lengthSquared > 0 {
            local = local * Matrix4x4(rotation: Quaternion(from: SIMD3(0, 0, -1), to: direction))
        }
        node.transform = state.transform * local
        return node
    }

    // MARK: Cameras

    /// A camera as a node: an orthographic camera's left, top, right and bottom; a view plane camera's distance to
    /// its plane, half its width and height there, and its centre; a view angle camera's field of view, in radians
    /// along its smaller dimension, and aspect ratio. `CameraPlacement` (location, point of interest, up) places it,
    /// and `CameraRange` (hither, yon) is its near and far.
    func camera(_ object: MetafileObject, state: State) throws(SceneFormatError) -> Node {
        var r = object.reader()
        var descriptor = CameraDescriptor()
        switch object.type {
        case .orthographicCamera:
            descriptor.usesOrthographicProjection = true
            if !r.isAtEnd {
                _ = try r.float32() // Left.
                let top = try r.float32()
                _ = try r.float32() // Right.
                let bottom = try r.float32()
                descriptor.orthographicScale = abs(top - bottom) / 2
            }
        case .viewPlaneCamera:
            if !r.isAtEnd {
                let distance = try r.float32()
                _ = try r.float32() // Half width.
                let halfHeight = try r.float32()
                if distance > 0 { descriptor.fieldOfView = degrees(radians: 2 * Elementary.atan(halfHeight / distance)) }
            }
        default:
            if !r.isAtEnd {
                descriptor.fieldOfView = degrees(radians: try r.float32())
                let aspect = r.isAtEnd ? 1 : try r.float32()
                descriptor.projectionDirection = aspect > 1 ? .vertical : .horizontal
            }
        }
        var location = SIMD3<Float>(0, 0, 10), target = SIMD3<Float>.zero, up = SIMD3<Float>(0, 1, 0)
        for child in object.children {
            var c = child.reader()
            switch child.type {
            case .cameraPlacement:
                location = try c.vector3()
                target = try c.vector3()
                up = try c.vector3()
            case .cameraRange:
                descriptor.zNear = max(try c.float32(), 1e-4)
                descriptor.zFar = max(try c.float32(), descriptor.zNear * 2)
            default:
                break
            }
        }
        let node = Node(name: Self.name(in: object.children))
        node.camera = Camera(descriptor)
        node.position = location
        node.look(at: target, up: up)
        node.transform = state.transform * node.transform
        return node
    }

    // MARK: Fill styles

    /// A triangle mesh's edges as lines, each once, or its corners as points, for the edges and points fill styles.
    /// Edges and corners are the same where their positions are, even across vertices split for flat faces. Meshes
    /// already of lines or points are as they are.
    static func outline(_ mesh: MeshBuffer, points: Bool) -> MeshBuffer {
        guard mesh.submeshes.allSatisfy({ $0.primitive == .triangles || $0.primitive == .triangleStrip }) else { return mesh }
        let positions = mesh.positions
        /// A position as a key: its bits, so equal positions match exactly.
        func key(_ v: Int) -> SIMD3<UInt32> {
            let p = positions[v]
            return SIMD3(p.x.bitPattern, p.y.bitPattern, p.z.bitPattern)
        }
        var indices: [Int] = []
        var submeshes: [Submesh] = []
        for submesh in mesh.submeshes {
            let start = indices.count
            let triangles = mesh.triangles(in: submesh)
            if points {
                var seen = Set<SIMD3<UInt32>>()
                for t in triangles {
                    for v in [t.x, t.y, t.z] where seen.insert(key(v)).inserted { indices.append(v) }
                }
            } else {
                var seen = Set<[UInt32]>()
                for t in triangles {
                    for (a, b) in [(t.x, t.y), (t.y, t.z), (t.z, t.x)] {
                        let ka = key(a), kb = key(b)
                        let ordered = [ka.x, ka.y, ka.z].lexicographicallyPrecedes([kb.x, kb.y, kb.z])
                            ? [ka.x, ka.y, ka.z, kb.x, kb.y, kb.z] : [kb.x, kb.y, kb.z, ka.x, ka.y, ka.z]
                        if seen.insert(ordered).inserted { indices += [a, b] }
                    }
                }
            }
            submeshes.append(Submesh(primitive: points ? .points : .lines, range: start ..< indices.count, materialIndex: submesh.materialIndex, name: submesh.name))
        }
        return MeshBuffer(vertexCount: mesh.vertexCount, streams: mesh.streams, indices: IndexBuffer(indices), submeshes: submeshes, bounds: mesh.bounds)
    }
}
