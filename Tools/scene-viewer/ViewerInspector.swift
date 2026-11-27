import SceneCore
import SceneGraph

/// Keyboard-navigable hierarchy and geometry diagnostics drawn into the same command buffer.
struct ViewerInspector {
    var isVisible = false
    var showsNormals = false
    var selection = 0
    var rows: [(node: Node, depth: Int)] = []

    mutating func rebuild(_ scene: Scene) {
        rows = []
        func visit(_ node: Node, depth: Int) {
            rows.append((node, depth))
            for child in node.children { visit(child, depth: depth + 1) }
        }
        visit(scene.rootNode, depth: 0)
        selection = min(selection, max(rows.count - 1, 0))
    }

    var selectedNode: Node? { rows.indices.contains(selection) ? rows[selection].node : nil }

    mutating func move(_ amount: Int) { selection = min(max(selection + amount, 0), max(rows.count - 1, 0)) }

    func encode(into commands: inout RecordedCommandBuffer, fly: Bool, status: String) {
        if showsNormals {
            // Use the actual rendered meshes so skinned and morphed vertices remain in sync.
            let calls = commands.drawCalls
            for call in calls {
                guard let normals = call.mesh.stream(.normal) else { continue }
                let positions = call.mesh.positions
                let length = max(call.mesh.bounds.boundingSphere.radius * 0.04, 0.005)
                var lines: [SIMD3<Float>] = []
                let step = max(1, positions.count / 5000)
                for i in stride(from: 0, to: positions.count, by: step) {
                    guard normals.componentCount >= 3, i < normals.vertexCount else { continue }
                    let offset = i * normals.componentCount
                    let n = SIMD3(normals.data[offset], normals.data[offset + 1], normals.data[offset + 2])
                    lines += [positions[i], positions[i] + n.normalized * length]
                }
                let mesh = MeshBuffer(vertexCount: lines.count, streams: [VertexStream(semantic: .position, vectors: lines)],
                    submeshes: [Submesh(primitive: .lines, range: 0..<lines.count, materialIndex: 0)])
                commands.drawImmediate(mesh, materials: [.unlit(color: SIMD4(0, 1, 1, 1))], transform: call.worldTransform)
            }
        }
        guard isVisible else { return }
        let maxRows = max(1, min(35, commands.target.height / 20 - 8))
        let start = max(0, selection - maxRows + 1)
        var lines = ["H HIERARCHY  UP/DOWN SELECT", "V VISIBILITY  F FOCUS  TAB FLY", "N NORMALS  F2 WIRE  SPACE PAUSE", fly ? "FLY: WASD QE MOVE / DRAG LOOK" : "ORBIT: DRAG LOOK / WHEEL ZOOM", status]
        for i in start..<min(rows.count, start + maxRows) {
            let row = rows[i]
            let kind = row.node.geometry != nil ? "M" : row.node.light != nil ? "L" : row.node.camera != nil ? "C" : "-"
            let label = row.node.name ?? "UNNAMED"
            lines.append("\(i == selection ? ">" : " ")\(row.node.isHidden ? "X" : " ")\(String(repeating: " ", count: min(row.depth, 8)))\(kind) \(label)")
        }
        if let node = selectedNode {
            lines.append("VERTICES \(node.geometry?.mesh.vertexCount ?? 0) / CHILDREN \(node.children.count)")
            let p = node.position
            lines.append("POS \(p.x) \(p.y) \(p.z)")
        }
        let width = Float(commands.target.width), height = Float(commands.target.height)
        var positions: [SIMD3<Float>] = []
        var colors: [SIMD4<Float>] = []
        func rect(_ x: Float, _ y: Float, _ w: Float, _ h: Float, _ color: SIMD4<Float>) {
            let a = SIMD3<Float>(x / width * 2 - 1, 1 - y / height * 2, 0)
            let b = SIMD3<Float>((x + w) / width * 2 - 1, 1 - (y + h) / height * 2, 0)
            positions += [a, SIMD3(a.x, b.y, 0), b, a, b, SIMD3(b.x, a.y, 0)]
            colors += Array(repeating: color, count: 6)
        }
        rect(8, 8, min(width - 16, 620), Float(lines.count * 20 + 12), SIMD4(0.025, 0.03, 0.045, 1))
        for (row, line) in lines.enumerated() {
            for (column, character) in line.uppercased().prefix(49).enumerated() {
                let pattern = Self.font[character] ?? Self.font["?"] ?? []
                for (y, bits) in pattern.enumerated() {
                    for x in 0..<5 where bits & (1 << (4 - x)) != 0 {
                        rect(Float(16 + column * 12 + x * 2), Float(16 + row * 20 + y * 2), 2, 2, SIMD4(0.85, 0.9, 1, 1))
                    }
                }
            }
        }
        let mesh = MeshBuffer(vertexCount: positions.count,
            streams: [VertexStream(semantic: .position, vectors: positions), VertexStream(semantic: .color, componentCount: 4, data: colors.flatMap { [$0.x, $0.y, $0.z, $0.w] })],
            submeshes: [Submesh(range: 0..<positions.count, materialIndex: 0)])
        var material = MaterialDescriptor.unlit(color: SIMD4(repeating: 1))
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false
        material.isDoubleSided = true
        commands.setCamera(CameraUniforms(viewMatrix: .identity, projectionMatrix: .identity))
        commands.drawImmediate(mesh, materials: [material], transform: .identity)
    }

    // Original compact 5x7 glyphs; no platform font or text-rendering dependency.
    private static let font: [Character: [Int]] = [
        "A":[14,17,17,31,17,17,17], "B":[30,17,17,30,17,17,30], "C":[14,17,16,16,16,17,14],
        "D":[30,17,17,17,17,17,30], "E":[31,16,16,30,16,16,31], "F":[31,16,16,30,16,16,16],
        "G":[14,17,16,23,17,17,15], "H":[17,17,17,31,17,17,17], "I":[14,4,4,4,4,4,14],
        "J":[7,2,2,2,2,18,12], "K":[17,18,20,24,20,18,17], "L":[16,16,16,16,16,16,31],
        "M":[17,27,21,21,17,17,17], "N":[17,25,25,21,19,19,17], "O":[14,17,17,17,17,17,14],
        "P":[30,17,17,30,16,16,16], "Q":[14,17,17,17,21,18,13], "R":[30,17,17,30,20,18,17],
        "S":[15,16,16,14,1,1,30], "T":[31,4,4,4,4,4,4], "U":[17,17,17,17,17,17,14],
        "V":[17,17,17,17,17,10,4], "W":[17,17,17,21,21,21,10], "X":[17,17,10,4,10,17,17],
        "Y":[17,17,10,4,4,4,4], "Z":[31,1,2,4,8,16,31], "0":[14,17,19,21,25,17,14],
        "1":[4,12,4,4,4,4,14], "2":[14,17,1,2,4,8,31], "3":[30,1,1,14,1,1,30],
        "4":[2,6,10,18,31,2,2], "5":[31,16,16,30,1,1,30], "6":[14,16,16,30,17,17,14],
        "7":[31,1,2,4,8,8,8], "8":[14,17,17,14,17,17,14], "9":[14,17,17,15,1,1,14],
        "&":[12,18,20,8,21,18,13], "(":[2,4,8,8,8,4,2], ")":[8,4,2,2,2,4,8], " ":[], "-":[0,0,0,31,0,0,0], ".":[0,0,0,0,0,12,12], ":":[0,12,12,0,12,12,0],
        "/":[1,2,2,4,8,8,16], ">" :[16,8,4,2,4,8,16], "?" :[14,17,1,2,4,0,4], "_" :[0,0,0,0,0,0,31]
    ]
}
