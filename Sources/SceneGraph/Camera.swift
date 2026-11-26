import SceneCore

/// A camera a node carries: a shared, mutable reference to a `CameraDescriptor`. It looks down the node's -z axis.
public final class Camera {

    public var name: String?

    public var descriptor: CameraDescriptor

    public init(_ descriptor: CameraDescriptor = CameraDescriptor()) {
        self.descriptor = descriptor
    }

    /// In degrees.
    public var fieldOfView: Float {
        get { descriptor.fieldOfView }
        set { descriptor.fieldOfView = newValue }
    }

    public var projectionDirection: CameraDescriptor.ProjectionDirection {
        get { descriptor.projectionDirection }
        set { descriptor.projectionDirection = newValue }
    }

    public var usesOrthographicProjection: Bool {
        get { descriptor.usesOrthographicProjection }
        set { descriptor.usesOrthographicProjection = newValue }
    }

    public var orthographicScale: Float {
        get { descriptor.orthographicScale }
        set { descriptor.orthographicScale = newValue }
    }

    public var zNear: Float {
        get { descriptor.zNear }
        set { descriptor.zNear = newValue }
    }

    public var zFar: Float {
        get { descriptor.zFar }
        set { descriptor.zFar = newValue }
    }

    public func projectionMatrix(aspectRatio: Float) -> Matrix4x4 {
        descriptor.projectionMatrix(aspectRatio: aspectRatio)
    }
}
