import SceneCore

/// A built-in shape, by its dimensions.
///
/// Each one's triangles are wound counter-clockwise from outside, with texture coordinates 0, 0 at an image's
/// top left. Boxes have six submeshes (front, right, back, left, top, bottom, as SceneKit orders its
/// materials); cylinders and cones three (side, top, bottom); tubes four (outside, inside, top, bottom);
/// pyramids five (front, right, back, left, bottom); spheres, planes, floors, toruses and capsules one.
public enum Primitive: Hashable, Sendable {
    case box(width: Float, height: Float, length: Float)
    case sphere(radius: Float, segmentCount: Int = 48)
    /// In the plane of x and y, facing +z.
    case plane(width: Float, height: Float)
    /// The plane of x and z, facing up; a width or length of 0 reaches far.
    case floor(width: Float = 0, length: Float = 0)
    case cylinder(radius: Float, height: Float, radialSegmentCount: Int = 48)
    case cone(topRadius: Float, bottomRadius: Float, height: Float, radialSegmentCount: Int = 48)
    case tube(innerRadius: Float, outerRadius: Float, height: Float, radialSegmentCount: Int = 48)
    case torus(ringRadius: Float, pipeRadius: Float, ringSegmentCount: Int = 48, pipeSegmentCount: Int = 24)
    /// Standing on the plane of x and z, its point above the middle.
    case pyramid(width: Float, height: Float, length: Float)
    /// A cylinder with round ends; the height includes them.
    case capsule(capRadius: Float, height: Float, radialSegmentCount: Int = 48, capSegmentCount: Int = 12)

    public func makeMesh() -> MeshBuffer {
        switch self {
        case let .box(width, height, length): .box(width: width, height: height, length: length)
        case let .sphere(radius, segments): .sphere(radius: radius, segmentCount: segments)
        case let .plane(width, height): .plane(width: width, height: height)
        case let .floor(width, length): .floor(width: width, length: length)
        case let .cylinder(radius, height, segments): .cylinder(radius: radius, height: height, radialSegmentCount: segments)
        case let .cone(top, bottom, height, segments): .cone(topRadius: top, bottomRadius: bottom, height: height, radialSegmentCount: segments)
        case let .tube(inner, outer, height, segments): .tube(innerRadius: inner, outerRadius: outer, height: height, radialSegmentCount: segments)
        case let .torus(ring, pipe, segments, pipeSegments): .torus(ringRadius: ring, pipeRadius: pipe, ringSegmentCount: segments, pipeSegmentCount: pipeSegments)
        case let .pyramid(width, height, length): .pyramid(width: width, height: height, length: length)
        case let .capsule(radius, height, segments, capSegments): .capsule(capRadius: radius, height: height, radialSegmentCount: segments, capSegmentCount: capSegments)
        }
    }
}

// MARK: - Meshes

public extension MeshBuffer {

    static func box(width: Float, height: Float, length: Float) -> MeshBuffer {
        var mesh = PrimitiveBuilder()
        // Normal, then the axes the texture's s and t run along.
        let faces: [(n: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>)] = [
            (SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 1, 0)), (SIMD3(1, 0, 0), SIMD3(0, 0, -1), SIMD3(0, 1, 0)),
            (SIMD3(0, 0, -1), SIMD3(-1, 0, 0), SIMD3(0, 1, 0)), (SIMD3(-1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 0)),
            (SIMD3(0, 1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, -1)), (SIMD3(0, -1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1)),
        ]
        let half = SIMD3(width, height, length) / 2
        func extent(_ a: SIMD3<Float>) -> Float { abs(a.x) * half.x + abs(a.y) * half.y + abs(a.z) * half.z }
        for face in faces {
            mesh.element { mesh in
                let center = face.n * extent(face.n)
                func corner(_ i: Float, _ j: Float) {
                    let p = center + face.u * (extent(face.u) * i) + face.v * (extent(face.v) * j)
                    mesh.vertex(p, face.n, (i + 1) / 2, (1 - j) / 2)
                }
                corner(-1, -1); corner(1, -1); corner(1, 1)
                corner(-1, -1); corner(1, 1); corner(-1, 1)
            }
        }
        return mesh.build()
    }

    static func plane(width: Float, height: Float) -> MeshBuffer {
        var mesh = PrimitiveBuilder()
        mesh.element { mesh in
            func corner(_ i: Float, _ j: Float) {
                mesh.vertex(SIMD3(i * width / 2, j * height / 2, 0), SIMD3(0, 0, 1), (i + 1) / 2, (1 - j) / 2)
            }
            corner(-1, -1); corner(1, -1); corner(1, 1)
            corner(-1, -1); corner(1, 1); corner(-1, 1)
        }
        return mesh.build()
    }

    /// A floor's texture is laid out once every hundred units, as SceneKit's is; a material's contents
    /// transform then scales it.
    static func floor(width: Float = 0, length: Float = 0) -> MeshBuffer {
        var mesh = PrimitiveBuilder()
        let far: Float = 2000
        let w = (width > 0 ? width : far) / 2, l = (length > 0 ? length : far) / 2
        mesh.element { mesh in
            func corner(_ i: Float, _ j: Float) {
                mesh.vertex(SIMD3(i * w, 0, j * l), SIMD3(0, 1, 0), i * w / 100 + 0.5, j * l / 100 + 0.5)
            }
            corner(-1, 1); corner(1, 1); corner(1, -1)
            corner(-1, 1); corner(1, -1); corner(-1, -1)
        }
        return mesh.build()
    }

    static func sphere(radius: Float, segmentCount: Int = 48) -> MeshBuffer {
        let slices = max(segmentCount, 3), stacks = max(slices / 2, 2)
        var mesh = PrimitiveBuilder()
        mesh.element { mesh in
            func point(_ i: Int, _ j: Int) {
                let theta = Float.pi * Float(i) / Float(stacks), phi = 2 * Float.pi * Float(j) / Float(slices)
                let n = SIMD3(Elementary.sin(theta) * Elementary.sin(phi), Elementary.cos(theta), Elementary.sin(theta) * Elementary.cos(phi))
                mesh.vertex(n * radius, n, Float(j) / Float(slices), Float(i) / Float(stacks))
            }
            for i in 0..<stacks {
                for j in 0..<slices {
                    point(i, j); point(i + 1, j); point(i + 1, j + 1)
                    point(i, j); point(i + 1, j + 1); point(i, j + 1)
                }
            }
        }
        return mesh.build()
    }

    static func cylinder(radius: Float, height: Float, radialSegmentCount: Int = 48) -> MeshBuffer {
        cone(topRadius: radius, bottomRadius: radius, height: height, radialSegmentCount: radialSegmentCount)
    }

    /// A cylinder or cone about the y axis; a cap with no radius is left out, its submesh empty.
    static func cone(topRadius top: Float, bottomRadius bottom: Float, height: Float, radialSegmentCount: Int = 48) -> MeshBuffer {
        let slices = max(radialSegmentCount, 3), half = height / 2
        func angle(_ j: Int) -> Float { 2 * Float.pi * Float(j) / Float(slices) }
        var mesh = PrimitiveBuilder()
        mesh.element { mesh in
            // The side leans by the radii's difference; its normal does too.
            let slope = bottom - top
            let length = (height * height + slope * slope).squareRoot()
            func point(_ j: Int, top isTop: Bool) {
                let phi = angle(j), radius = isTop ? top : bottom
                let s = Elementary.sin(phi), c = Elementary.cos(phi)
                let n = SIMD3(s * height / length, slope / length, c * height / length)
                mesh.vertex(SIMD3(s * radius, isTop ? half : -half, c * radius), n, Float(j) / Float(slices), isTop ? 0 : 1)
            }
            for j in 0..<slices {
                point(j, top: true); point(j, top: false); point(j + 1, top: false)
                point(j, top: true); point(j + 1, top: false); point(j + 1, top: true)
            }
        }
        for (isTop, radius) in [(true, top), (false, bottom)] {
            mesh.element { mesh in
                guard radius > 0 else { return }
                let y = isTop ? half : -half, n = SIMD3<Float>(0, isTop ? 1 : -1, 0)
                func rim(_ j: Int) {
                    let s = Elementary.sin(angle(j)), c = Elementary.cos(angle(j))
                    mesh.vertex(SIMD3(s * radius, y, c * radius), n, 0.5 + s / 2, 0.5 + c / 2)
                }
                for j in 0..<slices {
                    mesh.vertex(SIMD3(0, y, 0), n, 0.5, 0.5)
                    if isTop { rim(j); rim(j + 1) } else { rim(j + 1); rim(j) }
                }
            }
        }
        return mesh.build()
    }

    /// A tube about the y axis: its outside, its inside (which faces the axis), and the rings at its ends.
    static func tube(innerRadius inner: Float, outerRadius outer: Float, height: Float, radialSegmentCount: Int = 48) -> MeshBuffer {
        let slices = max(radialSegmentCount, 3), half = height / 2
        func angle(_ j: Int) -> Float { 2 * Float.pi * Float(j) / Float(slices) }
        var mesh = PrimitiveBuilder()
        for (radius, facing) in [(outer, Float(1)), (inner, Float(-1))] {
            mesh.element { mesh in
                func point(_ j: Int, top: Bool) {
                    let s = Elementary.sin(angle(j)), c = Elementary.cos(angle(j))
                    mesh.vertex(SIMD3(s * radius, top ? half : -half, c * radius), SIMD3(s * facing, 0, c * facing),
                                Float(j) / Float(slices), top ? 0 : 1)
                }
                for j in 0..<slices {
                    if facing > 0 {
                        point(j, top: true); point(j, top: false); point(j + 1, top: false)
                        point(j, top: true); point(j + 1, top: false); point(j + 1, top: true)
                    } else {
                        point(j, top: true); point(j + 1, top: false); point(j, top: false)
                        point(j, top: true); point(j + 1, top: true); point(j + 1, top: false)
                    }
                }
            }
        }
        for isTop in [true, false] {
            mesh.element { mesh in
                guard outer > inner else { return }
                let y = isTop ? half : -half, n = SIMD3<Float>(0, isTop ? 1 : -1, 0)
                func rim(_ j: Int, _ radius: Float) {
                    let s = Elementary.sin(angle(j)), c = Elementary.cos(angle(j)), reach = radius / outer / 2
                    mesh.vertex(SIMD3(s * radius, y, c * radius), n, 0.5 + s * reach, 0.5 + c * reach)
                }
                for j in 0..<slices {
                    if isTop {
                        rim(j, inner); rim(j, outer); rim(j + 1, outer)
                        rim(j, inner); rim(j + 1, outer); rim(j + 1, inner)
                    } else {
                        rim(j, inner); rim(j + 1, outer); rim(j, outer)
                        rim(j, inner); rim(j + 1, inner); rim(j + 1, outer)
                    }
                }
            }
        }
        return mesh.build()
    }

    /// A torus about the y axis: a pipe bent round a ring in the plane of x and z.
    static func torus(ringRadius ring: Float, pipeRadius pipe: Float, ringSegmentCount: Int = 48, pipeSegmentCount: Int = 24) -> MeshBuffer {
        let slices = max(ringSegmentCount, 3), sides = max(pipeSegmentCount, 3)
        var mesh = PrimitiveBuilder()
        mesh.element { mesh in
            func point(_ i: Int, _ j: Int) {
                let phi = 2 * Float.pi * Float(i) / Float(slices), theta = 2 * Float.pi * Float(j) / Float(sides)
                // Out from the ring's circle, by the pipe's angle.
                let n = SIMD3(Elementary.sin(phi) * Elementary.cos(theta), Elementary.sin(theta), Elementary.cos(phi) * Elementary.cos(theta))
                let center = SIMD3(Elementary.sin(phi) * ring, 0, Elementary.cos(phi) * ring)
                mesh.vertex(center + n * pipe, n, Float(i) / Float(slices), Float(j) / Float(sides))
            }
            for i in 0..<slices {
                for j in 0..<sides {
                    point(i, j); point(i + 1, j); point(i + 1, j + 1)
                    point(i, j); point(i + 1, j + 1); point(i, j + 1)
                }
            }
        }
        return mesh.build()
    }

    static func pyramid(width: Float, height: Float, length: Float) -> MeshBuffer {
        let w = width / 2, l = length / 2
        let apex = SIMD3<Float>(0, height, 0)
        // The base's corners, counter-clockwise from above, from the front's left.
        let corners: [SIMD3<Float>] = [SIMD3(-w, 0, l), SIMD3(w, 0, l), SIMD3(w, 0, -l), SIMD3(-w, 0, -l)]
        var mesh = PrimitiveBuilder()
        for side in 0..<4 {
            mesh.element { mesh in
                let a = corners[side], b = corners[(side + 1) % 4]
                let n = (b - a).cross(apex - a).normalized
                mesh.vertex(a, n, 0, 1); mesh.vertex(b, n, 1, 1); mesh.vertex(apex, n, 0.5, 0)
            }
        }
        mesh.element { mesh in
            let n = SIMD3<Float>(0, -1, 0)
            mesh.vertex(SIMD3(-w, 0, -l), n, 0, 0); mesh.vertex(SIMD3(w, 0, -l), n, 1, 0); mesh.vertex(SIMD3(w, 0, l), n, 1, 1)
            mesh.vertex(SIMD3(-w, 0, -l), n, 0, 0); mesh.vertex(SIMD3(w, 0, l), n, 1, 1); mesh.vertex(SIMD3(-w, 0, l), n, 0, 1)
        }
        return mesh.build()
    }

    /// A capsule about the y axis: two hemispheres joined by a cylinder, wound as the sphere is.
    static func capsule(capRadius radius: Float, height: Float, radialSegmentCount: Int = 48, capSegmentCount: Int = 12) -> MeshBuffer {
        let slices = max(radialSegmentCount, 3), caps = max(capSegmentCount, 1)
        let body = max(height - 2 * radius, 0) / 2
        // The rings from the top down: the top cap's, then the bottom cap's, the equators repeated so the
        // band between them is the cylinder.
        var rings: [(theta: Float, y: Float)] = []
        for i in 0...caps { rings.append((Float.pi / 2 * Float(i) / Float(caps), body)) }
        for i in 0...caps { rings.append((Float.pi / 2 * (1 + Float(i) / Float(caps)), -body)) }
        var mesh = PrimitiveBuilder()
        mesh.element { mesh in
            func point(_ i: Int, _ j: Int) {
                let (theta, offset) = rings[i], phi = 2 * Float.pi * Float(j) / Float(slices)
                let n = SIMD3(Elementary.sin(theta) * Elementary.sin(phi), Elementary.cos(theta), Elementary.sin(theta) * Elementary.cos(phi))
                mesh.vertex(n * radius + SIMD3(0, offset, 0), n, Float(j) / Float(slices), Float(i) / Float(rings.count - 1))
            }
            for i in 0..<(rings.count - 1) {
                for j in 0..<slices {
                    point(i, j); point(i + 1, j); point(i + 1, j + 1)
                    point(i, j); point(i + 1, j + 1); point(i, j + 1)
                }
            }
        }
        return mesh.build()
    }
}

// MARK: - Builder

/// Gathers a primitive's vertices, in runs that are its submeshes.
struct PrimitiveBuilder {

    private var positions: [Float] = []
    private var normals: [Float] = []
    private var textureCoordinates: [Float] = []
    private var submeshes: [Submesh] = []

    private var count: Int { positions.count / 3 }

    mutating func vertex(_ p: SIMD3<Float>, _ n: SIMD3<Float>, _ s: Float, _ t: Float) {
        positions.append(contentsOf: [p.x, p.y, p.z])
        normals.append(contentsOf: [n.x, n.y, n.z])
        textureCoordinates.append(contentsOf: [s, t])
    }

    /// Runs `body` as one submesh: the vertices it adds.
    mutating func element(_ body: (inout PrimitiveBuilder) -> Void) {
        let first = count
        body(&self)
        submeshes.append(Submesh(range: first ..< count, materialIndex: submeshes.count))
    }

    func build() -> MeshBuffer {
        MeshBuffer(
            vertexCount: count,
            streams: [
                VertexStream(semantic: .position, componentCount: 3, data: positions),
                VertexStream(semantic: .normal, componentCount: 3, data: normals),
                VertexStream(semantic: .textureCoordinate(0), componentCount: 2, data: textureCoordinates),
            ],
            submeshes: submeshes
        )
    }
}
