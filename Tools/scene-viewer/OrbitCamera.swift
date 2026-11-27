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

    /// Changes the look direction while keeping the camera's eye fixed.
    mutating func look(dx: Float, dy: Float) {
        let eye = target + offset * distance
        drag(dx: dx, dy: dy)
        target = eye - offset * distance
    }

    mutating func move(forward: Float, right: Float, up: Float, seconds: Float) {
        let forwardAxis = -offset
        let rightAxis = forwardAxis.cross(SIMD3(0, 1, 0)).normalized
        let movement = forwardAxis * forward + rightAxis * right + SIMD3(0, up, 0)
        target += movement * seconds * max(distance, 0.1)
    }

    mutating func zoom(_ amount: Float) {
        distance = min(max(distance * Elementary.pow(0.9, amount), 0.0001), 1e9)
    }

    var offset: SIMD3<Float> {
        SIMD3(
            Elementary.cos(pitch) * Elementary.sin(yaw),
            Elementary.sin(pitch),
            Elementary.cos(pitch) * Elementary.cos(yaw)
        )
    }

    func apply(to node: Node) {
        node.position = target + offset * distance
        node.look(at: target)
    }
}
