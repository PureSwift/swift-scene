import SceneCore

/// Changes to a scene grouped to be done together.
///
/// Changes are made at once, not animated: the duration says when the completion runs, in the scene's time.
public struct Transaction {

    public var animationDuration: Duration

    public var timingMode: Action.TimingMode

    public var disableActions: Bool

    public var completion: (() -> Void)?

    public init(
        animationDuration: Duration = .milliseconds(250),
        timingMode: Action.TimingMode = .linear,
        disableActions: Bool = false,
        completion: (() -> Void)? = nil
    ) {
        self.animationDuration = animationDuration
        self.timingMode = timingMode
        self.disableActions = disableActions
        self.completion = completion
    }
}

public extension Scene {

    /// Makes the changes, then runs the transaction's completion once its duration has passed in the scene.
    func perform<R>(_ transaction: Transaction = Transaction(), _ changes: () throws -> R) rethrows -> R {
        let result = try changes()
        if let completion = transaction.completion {
            if transaction.animationDuration <= .zero {
                completion()
            } else {
                pendingCompletions.append((time + transaction.animationDuration, completion))
            }
        }
        return result
    }
}
