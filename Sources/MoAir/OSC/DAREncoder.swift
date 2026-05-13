import Foundation
import OSCKit

enum DAREncoder {
    static func messages(for sample: HeadOrientation) -> [OSCMessage] {
        let yaw = Float(sample.yawDegrees)
        let pitch = Float(sample.pitchDegrees)
        let roll = Float(sample.rollDegrees)
        let qw = Float(sample.quaternion.w)
        let qx = Float(sample.quaternion.x)
        let qy = Float(sample.quaternion.y)
        let qz = Float(sample.quaternion.z)

        return [
            OSCMessage("/ypr", values: [yaw, pitch, roll]),
            OSCMessage("/quaternion", values: [qw, qx, qy, qz]),
        ]
    }
}
