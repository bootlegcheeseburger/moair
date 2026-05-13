import Foundation
import OSCKit

// Virtuoso (and other consumers of the Supperware Bridgehead head-tracking
// profile) listens on UDP port 8000 by default and expects three separate
// OSC messages per frame: /yaw, /pitch, /roll, each carrying a single float
// in degrees. A user-supplied addressPrefix is honoured so non-default
// Virtuoso routings (or Bridgehead-style /[yaw,pitch,roll] hosts) can still
// be targeted.
enum VirtuosoEncoder {
    static func messages(for sample: HeadOrientation, prefix: String) -> [OSCMessage] {
        let p = normalizedPrefix(prefix)
        let yaw = Float(sample.yawDegrees)
        let pitch = Float(sample.pitchDegrees)
        let roll = Float(sample.rollDegrees)
        return [
            OSCMessage("\(p)/yaw", values: [yaw]),
            OSCMessage("\(p)/pitch", values: [pitch]),
            OSCMessage("\(p)/roll", values: [roll]),
        ]
    }

    private static func normalizedPrefix(_ prefix: String) -> String {
        let trimmed = prefix.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        let leading = trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
        return leading.hasSuffix("/") ? String(leading.dropLast()) : leading
    }
}
