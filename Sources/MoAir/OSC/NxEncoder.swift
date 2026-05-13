import Foundation
import OSCKit

// Nx head-tracker OSC schema. Used by:
//   - ASAF Panner (reverse-engineered from ASAF AAX v2.1.12;
//     /nxosc/quaternion is the panner binary's sole external tracker
//     method, with user-configurable host/port).
//   - Native Nx receivers (Nx Virtual Mix Room, Nx Ocean Way, etc).
//
// Wire format: 4 floats in (x, y, z, w) order. NOT the native
// (w, x, y, z) ordering used by DAR/ASAF /HeadPose.
//
// Coordinate frame: Nx assumes "look forward = identity" and typically
// expects negated yaw vs CoreMotion's raw output. We rely on
// HeadOrientation's existing axis correction (which already flips yaw
// for the Supperware/Bridgehead convention shared by DAR and Mach1)
// so the same quaternion should land correctly here. If axes look
// wrong in testing, swap/negate components below rather than re-derive
// from euler.
enum NxEncoder {
    static func messages(for sample: HeadOrientation) -> [OSCMessage] {
        let qx = Float(sample.quaternion.x)
        let qy = Float(sample.quaternion.y)
        let qz = Float(sample.quaternion.z)
        let qw = Float(sample.quaternion.w)
        return [
            OSCMessage("/nxosc/quaternion", values: [qx, qy, qz, qw]),
        ]
    }
}
