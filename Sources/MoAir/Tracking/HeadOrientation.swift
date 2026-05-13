import Foundation
import CoreMotion

struct HeadOrientation: Equatable, Sendable {
    var quaternion: SIMDQuaternion
    var yawDegrees: Double
    var pitchDegrees: Double
    var rollDegrees: Double
    var rotationRate: SIMDVector3
    var gravity: SIMDVector3
    var sourceTimestamp: TimeInterval
    var receivedAt: TimeInterval

    static let zero = HeadOrientation(
        quaternion: .identity,
        yawDegrees: 0, pitchDegrees: 0, rollDegrees: 0,
        rotationRate: .zero, gravity: .zero,
        sourceTimestamp: 0, receivedAt: 0
    )

    func relative(to reference: SIMDQuaternion) -> HeadOrientation {
        let delta = reference.inverse * quaternion
        let (yaw, pitch, roll) = delta.toEulerYPR()
        return HeadOrientation(
            quaternion: delta,
            // Negate yaw so positive = head turns right, matching the
            // Supperware/Bridgehead OSC convention used by DAR, APL
            // Virtuoso, and Mach1. CoreMotion's native
            // convention (positive = counterclockwise from above = head
            // turns left) is the opposite, so flipping here keeps every
            // downstream encoder honest without a per-encoder fix.
            yawDegrees: -yaw, pitchDegrees: pitch, rollDegrees: roll,
            rotationRate: rotationRate,
            gravity: gravity,
            sourceTimestamp: sourceTimestamp,
            receivedAt: receivedAt
        )
    }
}

struct SIMDQuaternion: Equatable, Sendable {
    var w: Double
    var x: Double
    var y: Double
    var z: Double

    static let identity = SIMDQuaternion(w: 1, x: 0, y: 0, z: 0)

    var inverse: SIMDQuaternion {
        let n = w*w + x*x + y*y + z*z
        guard n > 0 else { return .identity }
        return SIMDQuaternion(w: w/n, x: -x/n, y: -y/n, z: -z/n)
    }

    static func * (lhs: SIMDQuaternion, rhs: SIMDQuaternion) -> SIMDQuaternion {
        SIMDQuaternion(
            w: lhs.w*rhs.w - lhs.x*rhs.x - lhs.y*rhs.y - lhs.z*rhs.z,
            x: lhs.w*rhs.x + lhs.x*rhs.w + lhs.y*rhs.z - lhs.z*rhs.y,
            y: lhs.w*rhs.y - lhs.x*rhs.z + lhs.y*rhs.w + lhs.z*rhs.x,
            z: lhs.w*rhs.z + lhs.x*rhs.y - lhs.y*rhs.x + lhs.z*rhs.w
        )
    }

    // Tait-Bryan Z-X-Y intrinsic (yaw → pitch → roll), matching CoreMotion's
    // CMAttitude convention for headphone reference frames: X is lateral
    // (through the ears, +right), Y is longitudinal (out the face, +forward),
    // Z is vertical (out the top of the head, +up). The previous formula
    // assumed an aircraft Z-Y-X frame, which mapped head-pitch into
    // `rollDegrees` and head-roll into `pitchDegrees` — the axis swap users
    // saw in DAR/Virtuoso (e.g. nodding showed up as tilt).
    func toEulerYPR() -> (yaw: Double, pitch: Double, roll: Double) {
        let sinp = 2 * (w*x + y*z)
        let pitch = abs(sinp) >= 1 ? copysign(.pi/2, sinp) : asin(sinp)

        let sinyCosp = 2 * (w*z - x*y)
        let cosyCosp = 1 - 2 * (x*x + z*z)
        let yaw = atan2(sinyCosp, cosyCosp)

        let sinrCosp = 2 * (w*y - x*z)
        let cosrCosp = 1 - 2 * (x*x + y*y)
        let roll = atan2(sinrCosp, cosrCosp)

        let r2d = 180.0 / .pi
        return (yaw * r2d, pitch * r2d, roll * r2d)
    }
}

struct SIMDVector3: Equatable, Sendable {
    var x: Double
    var y: Double
    var z: Double
    static let zero = SIMDVector3(x: 0, y: 0, z: 0)
}

extension HeadOrientation {
    init(_ motion: CMDeviceMotion, receivedAt: TimeInterval) {
        let q = motion.attitude.quaternion
        let quat = SIMDQuaternion(w: q.w, x: q.x, y: q.y, z: q.z)
        // CMAttitude already gives yaw/pitch/roll in the headphone Z-X-Y frame,
        // so use those directly rather than re-deriving from the quaternion.
        // Yaw is negated to flip Apple's "positive = head turns left" into the
        // Supperware/Bridgehead OSC convention (positive = head turns right)
        // expected by DAR, Virtuoso, and Mach1.
        let r2d = 180.0 / .pi
        self.quaternion = quat
        self.yawDegrees = -motion.attitude.yaw * r2d
        self.pitchDegrees = motion.attitude.pitch * r2d
        self.rollDegrees = motion.attitude.roll * r2d
        self.rotationRate = SIMDVector3(
            x: motion.rotationRate.x,
            y: motion.rotationRate.y,
            z: motion.rotationRate.z
        )
        self.gravity = SIMDVector3(
            x: motion.gravity.x,
            y: motion.gravity.y,
            z: motion.gravity.z
        )
        self.sourceTimestamp = motion.timestamp
        self.receivedAt = receivedAt
    }
}
