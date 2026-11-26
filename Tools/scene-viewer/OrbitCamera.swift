import SceneCore
import SceneGraph

/// Turns a camera node about a target: dragging orbits, the wheel zooms.
struct OrbitCamera {

    var target: SIMD3<Float> = .zero

    /// About y, in radians.
    var yaw: Float = 0.6

    /// Above the target's horizon, in radians.
    var pitch: Float = 0.45

    var distance: Float = 5

    /// Radians a point of drag.
    var sensitivity: Float = 0.01

    mutating func drag(dx: Float, dy: Float) {
        yaw -= dx * sensitivity
        pitch = min(max(pitch + dy * sensitivity, -1.5), 1.5)
    }

    mutating func zoom(_ amount: Float) {
        distance = min(max(distance * Elementary.pow(0.9, amount), 0.5), 500)
    }

    func apply(to node: Node) {
        let offset = SIMD3(
            Elementary.cos(pitch) * Elementary.sin(yaw),
            Elementary.sin(pitch),
            Elementary.cos(pitch) * Elementary.cos(yaw)
        )
        node.position = target + offset * distance
        node.look(at: target)
    }
}
