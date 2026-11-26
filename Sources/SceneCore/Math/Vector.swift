#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WinSDK)
import ucrt
#endif

// The conventions: right-handed, y up, -z forward; angles in radians unless a
// name says degrees. Vectors are the standard library's SIMD types, so they
// are the same on every platform and convert to `simd` for free on Darwin.

public extension SIMD3 where Scalar == Float {

    /// The dot product.
    @inlinable
    func dot(_ other: SIMD3<Float>) -> Float { (self * other).sum() }

    /// The cross product, right-handed.
    @inlinable
    func cross(_ other: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(y * other.z - z * other.y, z * other.x - x * other.z, x * other.y - y * other.x)
    }

    @inlinable
    var lengthSquared: Float { dot(self) }

    @inlinable
    var length: Float { lengthSquared.squareRoot() }

    /// The vector scaled to unit length; zero stays zero.
    @inlinable
    var normalized: SIMD3<Float> {
        let length = self.length
        return length > 0 ? self / length : .zero
    }

    /// The vector with `w` added.
    @inlinable
    func extended(_ w: Float) -> SIMD4<Float> { SIMD4(self, w) }
}

public extension SIMD4 where Scalar == Float {

    @inlinable
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }

    @inlinable
    func dot(_ other: SIMD4<Float>) -> Float { (self * other).sum() }
}

// The C library's single precision functions, by name, so the rest of the
// package needs no platform imports.
package enum Elementary {
    package static func sin(_ x: Float) -> Float { sinf(x) }
    package static func cos(_ x: Float) -> Float { cosf(x) }
    package static func tan(_ x: Float) -> Float { tanf(x) }
    package static func asin(_ x: Float) -> Float { asinf(x) }
    package static func acos(_ x: Float) -> Float { acosf(x) }
    package static func atan(_ x: Float) -> Float { atanf(x) }
    package static func atan2(_ y: Float, _ x: Float) -> Float { atan2f(y, x) }
    package static func pow(_ x: Float, _ y: Float) -> Float { powf(x, y) }
    package static func fmod(_ x: Float, _ y: Float) -> Float { fmodf(x, y) }
}

/// Degrees as radians.
@inlinable
public func radians(degrees: Float) -> Float { degrees * .pi / 180 }

/// Radians as degrees.
@inlinable
public func degrees(radians: Float) -> Float { radians * 180 / .pi }
