import Foundation
import OSCKit

enum Mach1Encoder {
    static func messages(
        for sample: HeadOrientation,
        prefix: String,
        sequence: UInt32,
        sendTimestamp: Double
    ) -> [OSCMessage] {
        let p = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix

        let yaw = Float(sample.yawDegrees)
        let pitch = Float(sample.pitchDegrees)
        let roll = Float(sample.rollDegrees)
        let qw = Float(sample.quaternion.w)
        let qx = Float(sample.quaternion.x)
        let qy = Float(sample.quaternion.y)
        let qz = Float(sample.quaternion.z)

        return [
            OSCMessage("\(p)/orientation", values: [yaw, pitch, roll]),
            OSCMessage("\(p)/orientation/yaw", values: [yaw]),
            OSCMessage("\(p)/orientation/pitch", values: [pitch]),
            OSCMessage("\(p)/orientation/roll", values: [roll]),
            OSCMessage("\(p)/orientation/quat", values: [qw, qx, qy, qz]),
            OSCMessage("\(p)/moair/seq", values: [Int32(bitPattern: sequence)]),
            OSCMessage("\(p)/moair/ts", values: [sendTimestamp]),
        ]
    }
}
