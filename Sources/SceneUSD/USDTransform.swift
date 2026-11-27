import SceneCore
import SceneFormats
import SceneGraph

enum USDTransform {
    static func matrix(_ prim: USDPrim) throws(SceneFormatError) -> (matrix: Matrix4x4, reset: Bool) {
        guard let value = try USDRead.attribute(prim, "xformOpOrder", types: ["token[]"]) else { return (.identity, false) }
        var matrix = Matrix4x4.identity
        var reset = false
        for value in try USDRead.array(value) {
            var name = try USDRead.string(value)
            if name == "!resetXformStack!" { matrix = .identity; reset = true; continue }
            let inverted = name.hasPrefix("!invert!")
            if inverted { name = String(name.dropFirst(8)) }
            let components = name.split(separator: ":")
            guard components.count >= 2, components[0] == "xformOp" else { throw USDRead.invalid("Invalid xformOpOrder entry") }
            let kind = String(components[1])
            let types: [String]
            if kind == "transform" { types = ["matrix4d"] }
            else if kind == "orient" { types = ["quatf", "quatd", "quath"] }
            else if ["translate", "scale"].contains(kind) || kind.hasPrefix("rotate") && kind.count == 9 {
                types = ["float3", "double3", "half3"]
            } else { types = ["float", "double", "half"] }
            guard let value = try USDRead.attribute(prim, name, types: types) else { throw USDRead.invalid("Missing USD transform op \(name)") }
            var operation: Matrix4x4
            switch kind {
            case "translate", "scale":
                let v = try USDRead.tuple(value, count: 3)
                let vector = SIMD3(v[0], v[1], v[2])
                operation = kind == "translate" ? Matrix4x4(translation: vector) : Matrix4x4(scale: vector)
            case "transform":
                guard case .tuple(let rows) = value, rows.count == 4 else { throw USDRead.invalid("Invalid USD matrix") }
                var elements: [Float] = []
                for row in rows { elements += try USDRead.tuple(row, count: 4) }
                // USD uses row vectors and row-major matrices; transpose into our column-vector convention.
                operation = Matrix4x4(columnMajor: elements)
                guard operation[3, 0] == 0, operation[3, 1] == 0, operation[3, 2] == 0, operation[3, 3] == 1 else {
                    throw .unsupported("Non-affine USD transforms")
                }
            case "orient":
                let v = try USDRead.tuple(value, count: 4)
                let q = Quaternion(real: v[0], imag: SIMD3(v[1], v[2], v[3]))
                guard q.length > 0, q.length.isFinite else { throw USDRead.invalid("Invalid USD quaternion") }
                operation = Matrix4x4(rotation: q)
            case "rotateX", "rotateY", "rotateZ":
                operation = rotation(axis: kind.last ?? "X", angle: try USDRead.scalar(value))
            case "rotateXYZ", "rotateXZY", "rotateYXZ", "rotateYZX", "rotateZXY", "rotateZYX":
                let v = try USDRead.tuple(value, count: 3)
                operation = .identity
                for axis in kind.suffix(3) {
                    let index = axis == "X" ? 0 : axis == "Y" ? 1 : 2
                    operation = rotation(axis: axis, angle: v[index]) * operation
                }
            default: throw .unsupported("USD transform operation \(kind)")
            }
            if inverted {
                guard let inverse = operation.inverse else { throw USDRead.invalid("Singular inverse USD transform op") }
                operation = inverse
            }
            matrix *= operation
            guard matrix.columnMajorElements.allSatisfy({ $0.isFinite }) else { throw USDRead.invalid("USD transform overflow") }
        }
        return (matrix, reset)
    }

    private static func rotation(axis: Character, angle: Float) -> Matrix4x4 {
        let vector: SIMD3<Float> = axis == "X" ? SIMD3(1, 0, 0) : axis == "Y" ? SIMD3(0, 1, 0) : SIMD3(0, 0, 1)
        return Matrix4x4(rotation: Quaternion(angle: angle * (.pi / 180), axis: vector))
    }

    static func assign(_ matrix: Matrix4x4, to node: Node) throws(SceneFormatError) {
        guard matrix.columnMajorElements.allSatisfy({ $0.isFinite }) else { throw USDRead.invalid("Non-finite USD transform") }
        let decomposed = Transform(matrix: matrix)
        let matches = zip(matrix.columnMajorElements, decomposed.matrix.columnMajorElements).allSatisfy {
            abs($0 - $1) <= 1e-5 * max(1, abs($0))
        }
        if matches { node.localTransform = LocalTransform(transform: decomposed) }
        else {
            // LocalTransform multiplies by inverse(pivot); preserve shear/reflections without lossy TRS decomposition.
            guard let inverse = matrix.inverse, inverse.columnMajorElements.allSatisfy({ $0.isFinite }) else {
                throw .unsupported("Singular USD matrix cannot be represented by SceneGraph")
            }
            node.localTransform = LocalTransform(pivot: inverse)
        }
    }
}
