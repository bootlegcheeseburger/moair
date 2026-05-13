import Foundation
import OSCKit
import Combine

@MainActor
final class OSCBridge: ObservableObject {
    enum State: Equatable {
        case idle
        case sending
        case error(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var sentCount: UInt64 = 0
    @Published private(set) var sendErrorCount: UInt64 = 0
    @Published private(set) var lastSendError: String?
    @Published private(set) var measuredSendIntervalMs: Double = 0

    private let client = OSCUDPClient()
    private var sequence: UInt32 = 0
    private var lastSendAt: TimeInterval = 0

    var settings: OSCSettings = .darPreset

    func start() throws {
        try client.start()
        state = .sending
    }

    func stop() {
        client.stop()
        state = .idle
    }

    func send(_ sample: HeadOrientation) {
        guard state == .sending else { return }
        let now = Date().timeIntervalSince1970
        sequence &+= 1
        let messages: [OSCMessage]
        switch settings.schema {
        case .dar:
            messages = DAREncoder.messages(for: sample)
        case .mach1:
            messages = Mach1Encoder.messages(
                for: sample,
                prefix: settings.addressPrefix,
                sequence: sequence,
                sendTimestamp: now
            )
        case .virtuoso:
            messages = VirtuosoEncoder.messages(for: sample, prefix: settings.addressPrefix)
        case .asaf:
            messages = ASAFEncoder.messages(for: sample)
        case .nx:
            messages = NxEncoder.messages(for: sample)
        }
        do {
            for message in messages {
                try client.send(message, to: settings.host, port: settings.port)
            }
            sentCount &+= 1
            if lastSendAt > 0 {
                measuredSendIntervalMs = (now - lastSendAt) * 1000
            }
            lastSendAt = now
            if lastSendError != nil { lastSendError = nil }
        } catch {
            // Per-send failures (transient ENETDOWN, EHOSTUNREACH, etc.)
            // shouldn't brick the stream — surface via lastSendError and
            // keep state == .sending so the next sample tries again.
            sendErrorCount &+= 1
            lastSendError = String(describing: error)
        }
    }
}

enum OSCSchema: String, Codable, CaseIterable {
    case dar
    case mach1
    case virtuoso
    case asaf
    case nx
}

struct OSCSettings: Equatable, Codable {
    var host: String
    var port: UInt16
    var addressPrefix: String
    var schema: OSCSchema

    static let darPreset = OSCSettings(
        host: "127.0.0.1",
        port: 8000,
        addressPrefix: "",
        schema: .dar
    )

    static let mach1Preset = OSCSettings(
        host: "127.0.0.1",
        port: 9898,
        addressPrefix: "/m1",
        schema: .mach1
    )

    // Virtuoso's head-tracking profile: three separate float messages
    // (/yaw, /pitch, /roll) in degrees, on UDP 8000, no prefix.
    // Matches the Supperware Bridgehead default for Virtuoso.
    static let virtuosoPreset = OSCSettings(
        host: "127.0.0.1",
        port: 8000,
        addressPrefix: "",
        schema: .virtuoso
    )

    // ASAF Panner native head-tracker input: single /HeadPose message.
    // Host + port are user-configurable in the plugin ("OSC Head Tracker
    // Address" / "Port Number") with no shipped default — 8000 is our
    // suggestion; user must mirror it.
    static let asafPreset = OSCSettings(
        host: "127.0.0.1",
        port: 8000,
        addressPrefix: "",
        schema: .asaf
    )

    // Generic Nx receiver (Nx Virtual Mix Room, Nx Ocean Way, third-party
    // Nx-compatible plugins). Same wire format as ASAF; 4242 is a clean
    // differentiator from the ASAF preset.
    static let nxPreset = OSCSettings(
        host: "127.0.0.1",
        port: 4242,
        addressPrefix: "",
        schema: .nx
    )
}
