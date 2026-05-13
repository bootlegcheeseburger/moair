import Foundation

enum SystemProfilerProbe {
    struct Result {
        var batteryPercent: Int?
        var firmwareVersion: String?
        var address: String?
        var connected: Bool
        var rawJSON: Any?
    }

    static func airPodsMaxSnapshot() async -> Result? {
        await supportedHeadphoneSnapshot()
    }

    static func supportedHeadphoneSnapshot() async -> Result? {
        await Task.detached(priority: .utility) {
            runProbe()
        }.value
    }

    /// Names of every paired device that looks like a head-tracking-capable
    /// Apple-family headphone (vendor 0x004C + Bluetooth Minor Type
    /// "Headphones"), regardless of how the user has renamed it. Lets us
    /// recognise custom names like "dtap" without baking model-string
    /// substrings into AudioController.
    static func supportedHeadphoneDeviceNames() async -> [String] {
        await Task.detached(priority: .utility) {
            scanHeadphoneNames()
        }.value
    }

    private static func isSupportedModel(name: String, model: String) -> Bool {
        for s in [name, model] {
            let l = s.lowercased()
            if l.contains("airpods") || l.contains("beats fit pro") { return true }
        }
        return false
    }

    private static func isAppleHeadphoneEntry(_ attrs: [String: Any]) -> Bool {
        let vendor = (attrs["device_vendorID"] as? String) ?? ""
        let minor = (attrs["device_minorType"] as? String) ?? ""
        // Apple's vendor ID is 0x004C; Minor Type "Headphones" covers
        // AirPods 3 / Pro / 4 / Max and Beats Fit Pro.
        return vendor.lowercased().contains("0x004c") && minor.localizedCaseInsensitiveContains("headphones")
    }

    private static func scanHeadphoneNames() -> [String] {
        guard let parsed = parsedSystemProfiler() else { return [] }
        guard let bt = parsed["SPBluetoothDataType"] as? [Any] else { return [] }
        var names: [String] = []
        for entry in bt {
            guard let dict = entry as? [String: Any] else { continue }
            for key in ["device_connected", "device_not_connected"] {
                guard let list = dict[key] as? [Any] else { continue }
                for item in list {
                    guard let entryDict = item as? [String: Any] else { continue }
                    for (name, value) in entryDict {
                        guard let attrs = value as? [String: Any] else { continue }
                        if isAppleHeadphoneEntry(attrs) {
                            names.append(name)
                        }
                    }
                }
            }
        }
        return names
    }

    private static func parsedSystemProfiler() -> [String: Any]? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        task.arguments = ["SPBluetoothDataType", "-json"]
        let stdout = Pipe()
        task.standardOutput = stdout
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        task.waitUntilExit()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func runProbe() -> Result? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        task.arguments = ["SPBluetoothDataType", "-json"]
        let stdout = Pipe()
        task.standardOutput = stdout
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        task.waitUntilExit()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let bt = parsed["SPBluetoothDataType"] as? [Any] else { return nil }
        for entry in bt {
            guard let dict = entry as? [String: Any] else { continue }
            for key in ["device_connected", "device_not_connected"] {
                if let list = dict[key] as? [Any] {
                    if let r = scan(list) { return r }
                }
            }
        }
        return nil
    }

    private static func scan(_ list: [Any]) -> Result? {
        for item in list {
            guard let entry = item as? [String: Any] else { continue }
            for (name, value) in entry {
                guard let attrs = value as? [String: Any] else { continue }
                let model = (attrs["device_model"] as? String) ?? (attrs["device_minorType"] as? String) ?? ""
                if !isSupportedModel(name: name, model: model) { continue }
                let percentStr = (attrs["device_batteryLevelMain"] as? String)
                    ?? (attrs["device_batteryLevel"] as? String)
                let percent = percentStr.flatMap { s -> Int? in
                    let cleaned = s.replacingOccurrences(of: "%", with: "")
                    return Int(cleaned)
                }
                let connected = (attrs["device_isconnected"] as? String) == "attrib_Yes"
                return Result(
                    batteryPercent: percent,
                    firmwareVersion: attrs["device_firmwareVersion"] as? String,
                    address: attrs["device_address"] as? String,
                    connected: connected,
                    rawJSON: entry
                )
            }
        }
        return nil
    }
}
