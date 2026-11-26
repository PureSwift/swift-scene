import SceneCore

/// A change to a node over time: a move, a turn, a fade, a sequence of actions…
///
/// An action is a value: its definition, duration, timing mode and speed. Running it on a node makes a runner
/// that keeps what it needs between frames, so one action can run on any number of nodes at once. A runner is
/// given each frame's time and gives back what it did not use once it is done, which is how a sequence goes on
/// to its next action within the same frame.
public struct Action {

    indirect enum Kind {
        case move(SIMD3<Float>, relative: Bool)
        case rotateEuler(SIMD3<Float>, relative: Bool, shortest: Bool)
        case rotateAxis(axis: SIMD3<Float>, angle: Float, relative: Bool)
        case scale(SIMD3<Float>, relative: Bool)
        case fade(Float, relative: Bool)
        case hide(Bool)
        case wait
        case sequence([Action])
        case group([Action])
        case repeatCount(Action, Int)
        case forever(Action)
        case removeFromParent
        case run((Node) -> Void)
        case custom((Node, Duration) -> Void)
        case nothing
    }

    /// How an action's progress runs over its duration.
    public enum TimingMode: Hashable, Sendable {
        case linear
        case easeIn
        case easeOut
        case easeInEaseOut

        func eased(_ p: Float) -> Float {
            switch self {
            case .linear: p
            case .easeIn: p * p
            case .easeOut: 1 - (1 - p) * (1 - p)
            case .easeInEaseOut: p * p * (3 - 2 * p)
            }
        }
    }

    var kind: Kind

    public var duration: Duration {
        didSet { if duration < .zero { duration = .zero } }
    }

    public var timingMode: TimingMode = .linear

    /// How fast it runs: 2 is twice as fast; 0 holds it still.
    public var speed: Double = 1

    init(_ kind: Kind, duration: Duration = .zero) {
        self.kind = kind
        self.duration = max(duration, .zero)
    }
}

// MARK: - Making actions

public extension Action {

    static func move(by delta: SIMD3<Float>, duration: Duration) -> Action {
        Action(.move(delta, relative: true), duration: duration)
    }

    static func move(to position: SIMD3<Float>, duration: Duration) -> Action {
        Action(.move(position, relative: false), duration: duration)
    }

    /// Turns by pitch, yaw and roll: about x from outside, about y and z from inside.
    static func rotate(byEulerAngles angles: SIMD3<Float>, duration: Duration) -> Action {
        Action(.rotateEuler(angles, relative: true, shortest: false), duration: duration)
    }

    static func rotate(toEulerAngles angles: SIMD3<Float>, duration: Duration, shortestUnitArc: Bool = false) -> Action {
        Action(.rotateEuler(angles, relative: false, shortest: shortestUnitArc), duration: duration)
    }

    static func rotate(by angle: Float, around axis: SIMD3<Float>, duration: Duration) -> Action {
        Action(.rotateAxis(axis: axis, angle: angle, relative: true), duration: duration)
    }

    static func rotate(toAngle angle: Float, around axis: SIMD3<Float>, duration: Duration) -> Action {
        Action(.rotateAxis(axis: axis, angle: angle, relative: false), duration: duration)
    }

    static func scale(by factor: Float, duration: Duration) -> Action {
        Action(.scale(SIMD3(repeating: factor), relative: true), duration: duration)
    }

    static func scale(to scale: Float, duration: Duration) -> Action {
        Action(.scale(SIMD3(repeating: scale), relative: false), duration: duration)
    }

    static func fadeIn(duration: Duration) -> Action {
        Action(.fade(1, relative: false), duration: duration)
    }

    static func fadeOut(duration: Duration) -> Action {
        Action(.fade(0, relative: false), duration: duration)
    }

    static func fadeOpacity(by delta: Float, duration: Duration) -> Action {
        Action(.fade(delta, relative: true), duration: duration)
    }

    static func fadeOpacity(to opacity: Float, duration: Duration) -> Action {
        Action(.fade(opacity, relative: false), duration: duration)
    }

    static var hide: Action { Action(.hide(true)) }

    static var unhide: Action { Action(.hide(false)) }

    static func wait(duration: Duration) -> Action {
        Action(.wait, duration: duration)
    }

    /// Waits the duration, give or take up to half the range.
    static func wait(duration: Duration, withRange range: Duration) -> Action {
        Action(.wait, duration: duration + range * Double.random(in: -0.5...0.5))
    }

    /// Runs the actions one after another.
    static func sequence(_ actions: [Action]) -> Action {
        Action(.sequence(actions))
    }

    /// Runs the actions all at once, until the last is done.
    static func group(_ actions: [Action]) -> Action {
        Action(.group(actions))
    }

    static func `repeat`(_ action: Action, count: Int) -> Action {
        Action(.repeatCount(action, count))
    }

    static func repeatForever(_ action: Action) -> Action {
        Action(.forever(action))
    }

    static var removeFromParent: Action { Action(.removeFromParent) }

    /// Calls the closure with the node, at once.
    static func run(_ body: @escaping (Node) -> Void) -> Action {
        Action(.run(body))
    }

    /// Calls the closure every frame for the duration, with the node and the time elapsed.
    static func customAction(duration: Duration, _ body: @escaping (Node, Duration) -> Void) -> Action {
        Action(.custom(body), duration: duration)
    }

    func timingMode(_ mode: TimingMode) -> Action {
        var action = self
        action.timingMode = mode
        return action
    }

    func speed(_ speed: Double) -> Action {
        var action = self
        action.speed = speed
        return action
    }

    /// The action that undoes this one, as far as one can: moves, turns, scales and fades by an amount are
    /// reversed, a sequence runs its reversed actions the other way round, and the rest is as it is.
    func reversed() -> Action {
        var action = self
        switch kind {
        case .move(let v, true): action.kind = .move(-v, relative: true)
        case .rotateEuler(let v, true, let shortest): action.kind = .rotateEuler(-v, relative: true, shortest: shortest)
        case .rotateAxis(let axis, let angle, true): action.kind = .rotateAxis(axis: axis, angle: -angle, relative: true)
        case .scale(let v, true): action.kind = .scale(1 / v, relative: true)
        case .fade(let v, true): action.kind = .fade(-v, relative: true)
        case .fade(1, false): action.kind = .fade(0, relative: false)
        case .fade(0, false): action.kind = .fade(1, relative: false)
        case .hide(let hide): action.kind = .hide(!hide)
        case .sequence(let actions): action.kind = .sequence(actions.reversed().map { $0.reversed() })
        case .group(let actions): action.kind = .group(actions.map { $0.reversed() })
        case .repeatCount(let inner, let count): action.kind = .repeatCount(inner.reversed(), count)
        case .forever(let inner): action.kind = .forever(inner.reversed())
        default: break
        }
        return action
    }
}

// MARK: - Running on nodes

/// An action running on a node.
final class RunningAction {

    let key: String?
    let action: Action
    let runner: ActionRunner
    let completion: (() -> Void)?

    init(key: String?, action: Action, completion: (() -> Void)?) {
        self.key = key
        self.action = action
        self.runner = ActionRunner(action)
        self.completion = completion
    }
}

public extension Node {

    /// Runs the action; one with the key of one already running replaces it.
    func runAction(_ action: Action, forKey key: String? = nil, completion: (() -> Void)? = nil) {
        if let key { runningActions.removeAll { $0.key == key } }
        runningActions.append(RunningAction(key: key, action: action, completion: completion))
    }

    func removeAction(forKey key: String) {
        runningActions.removeAll { $0.key == key }
    }

    func removeAllActions() {
        runningActions.removeAll()
    }

    func action(forKey key: String) -> Action? {
        runningActions.first { $0.key == key }?.action
    }

    var actionKeys: [String] {
        runningActions.compactMap(\.key)
    }

    var hasActions: Bool { !runningActions.isEmpty }

    /// Moves every action on this node and those below on by the time, parents first, and calls the completions
    /// of those that finish.
    func advanceActions(by delta: Duration) {
        guard !isPaused else { return }
        let seconds = delta.seconds
        if !runningActions.isEmpty {
            // An action may change the list (run another, remove itself): run over a copy.
            let running = runningActions
            var finished: [RunningAction] = []
            for run in running where run.runner.advance(self, seconds) != nil {
                finished.append(run)
            }
            runningActions.removeAll { run in finished.contains { $0 === run } }
            for run in finished {
                run.completion?()
            }
        }
        for child in children {
            child.advanceActions(by: delta)
        }
    }
}

// MARK: - Runner

final class ActionRunner {

    private let action: Action
    private var elapsed = 0.0
    private var lastProgress: Float = 0
    private var started = false
    // What a runner of one action keeps: where an absolute action began, its children's runners, a repeat's count.
    private var startPosition = SIMD3<Float>.zero
    private var startEuler = SIMD3<Float>.zero
    private var startScale = SIMD3<Float>(repeating: 1)
    private var startOpacity: Float = 1
    private var startRotation = Quaternion.identity
    private var children: [ActionRunner] = []
    private var index = 0
    private var finishedChildren: [Double?] = []
    private var repeated = 0

    init(_ action: Action) {
        self.action = action
    }

    /// Moves the action on by `dt` seconds; nil while it goes on, else the time it did not need.
    func advance(_ node: Node, _ dt: Double) -> Double? {
        let speed = action.speed
        guard speed > 0 else { return nil }
        guard let left = run(node, dt * speed) else { return nil }
        return left / speed
    }

    private func run(_ node: Node, _ dt: Double) -> Double? {
        switch action.kind {
        case .hide(let hide):
            node.isHidden = hide
            return dt
        case .removeFromParent:
            node.removeFromParent()
            return dt
        case .nothing:
            return dt
        case .run(let body):
            body(node)
            return dt
        case .sequence(let actions):
            if children.isEmpty { children = actions.map(ActionRunner.init) }
            var left = dt
            while index < children.count {
                guard let remaining = children[index].advance(node, left) else { return nil }
                left = remaining
                index += 1
            }
            return left
        case .group(let actions):
            if children.isEmpty {
                children = actions.map(ActionRunner.init)
                finishedChildren = Array(repeating: nil, count: children.count)
            }
            var allDone = true, leftover = dt
            for i in children.indices {
                if finishedChildren[i] == nil { finishedChildren[i] = children[i].advance(node, dt) }
                if let left = finishedChildren[i] { leftover = min(leftover, left) } else { allDone = false }
            }
            return allDone ? leftover : nil
        case .repeatCount(let inner, let count):
            return runRepeat(node, dt, inner, count: count)
        case .forever(let inner):
            return runRepeat(node, dt, inner, count: nil)
        case .move, .rotateEuler, .rotateAxis, .scale, .fade, .wait, .custom:
            return runInterval(node, dt)
        }
    }

    private func runRepeat(_ node: Node, _ dt: Double, _ inner: Action, count: Int?) -> Double? {
        var left = dt
        var iterations = 0
        while count.map({ repeated < $0 }) ?? true {
            if children.isEmpty { children = [ActionRunner(inner)] }
            guard let remaining = children[0].advance(node, left) else { return nil }
            children = []
            repeated += 1
            // An action that takes no time must not spin: once a frame.
            if remaining >= left {
                iterations += 1
                if iterations > 1 { return nil }
            }
            left = remaining
        }
        return left
    }

    private func runInterval(_ node: Node, _ dt: Double) -> Double? {
        if !started {
            started = true
            startPosition = node.position
            startEuler = node.orientation.eulerAngles
            startScale = node.scale
            startOpacity = node.opacity
            startRotation = node.orientation
        }
        let duration = action.duration.seconds
        var step = dt
        if duration > 0 {
            step = min(dt, duration - elapsed)
            elapsed += step
        } else {
            elapsed = 0
        }
        let linear = duration > 0 ? Float(elapsed / duration) : 1
        apply(node, progress: action.timingMode.eased(linear), elapsed: elapsed)
        if duration <= 0 || elapsed >= duration { return dt - step }
        return nil
    }

    private func apply(_ node: Node, progress p: Float, elapsed: Double) {
        let step = p - lastProgress
        lastProgress = p
        switch action.kind {
        case .move(let v, let relative):
            node.position = relative ? node.position + v * step : startPosition + (v - startPosition) * p
        case .rotateEuler(let v, let relative, let shortest):
            if relative {
                // Each angle's turn added: about x from outside, about y and z from inside, which is the angles'
                // sums for a node that is not rolled.
                let dx = Quaternion(angle: v.x * step, axis: SIMD3(1, 0, 0))
                let dy = Quaternion(angle: v.y * step, axis: SIMD3(0, 1, 0))
                let dz = Quaternion(angle: v.z * step, axis: SIMD3(0, 0, 1))
                node.orientation = dx * node.orientation * dy * dz
            } else if shortest {
                node.orientation = .slerp(from: startRotation, to: Quaternion(eulerAngles: v), t: p)
            } else {
                node.orientation = Quaternion(eulerAngles: startEuler + (v - startEuler) * p)
            }
        case .rotateAxis(let axis, let angle, let relative):
            if relative {
                node.orientation = Quaternion(angle: angle * step, axis: axis) * node.orientation
            } else {
                node.orientation = Quaternion(angle: angle * p, axis: axis)
            }
        case .scale(let v, let relative):
            if relative {
                node.scale *= SIMD3(Elementary.pow(v.x, step), Elementary.pow(v.y, step), Elementary.pow(v.z, step))
            } else {
                node.scale = startScale + (v - startScale) * p
            }
        case .fade(let v, let relative):
            node.opacity = relative ? node.opacity + v * step : startOpacity + (v - startOpacity) * p
        case .custom(let body):
            body(node, .seconds(elapsed))
        default:
            break
        }
    }
}

extension Duration {

    /// The duration in seconds.
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) * 1e-18
    }
}
