import Foundation
import OSCKit

// ASAF Panner native head-tracker input.
//
// Address: /HeadPose (per the plugin UI; the binary literal is /HeadPos
// without an 'e' but the panner accepts /HeadPose).
// Host + port: user-configurable via the plugin's "OSC Head Tracker
// Address" / "Port Number" fields. MoAir's asafPreset suggests 8000.
//
// Payload: Apple's CMAttitude quaternion sent in SCALAR-LAST order
// (x, y, z, w). The panner expects this convention and renders Apple's
// quaternion directly — no basis swap, no rest-pose offset.
//
// Determined empirically: scalar-first sends (w-first) produced
// cascading axis/handedness/rest-pose mismatches that no rotation
// composition could fully resolve. Switching to scalar-last made
// everything land in one shot.
enum ASAFEncoder {
    static func messages(for sample: HeadOrientation) -> [OSCMessage] {
        let qw = Float(sample.quaternion.w)
        let qx = Float(sample.quaternion.x)
        let qy = Float(sample.quaternion.y)
        let qz = Float(sample.quaternion.z)
        return [
            OSCMessage("/HeadPose", values: [qx, qy, qz, qw]),
        ]
    }
}
