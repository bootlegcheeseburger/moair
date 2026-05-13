import Foundation
import CoreAudio
import AudioToolbox
import Combine
import os.log

/// Unified-logging shim — `print()` only writes to stdout, which isn't
/// visible when MoAir runs as a launched .app. Routing diagnostics
/// through `Logger` lets `log stream --process MoAir` or
/// `log stream --subsystem com.bootlegcheeseburger.moair --category audio`
/// pick them up consistently.
private let audioLog = Logger(subsystem: "com.bootlegcheeseburger.moair", category: "audio")

@MainActor
final class AudioController: ObservableObject {
    enum Transport: Equatable {
        case bluetooth
        case usb
        case other(String)

        var label: String {
            switch self {
            case .bluetooth: return "Bluetooth"
            case .usb: return "Wired"
            case .other(let s): return s
            }
        }

        var supportsCalibratedDecibels: Bool {
            self == .usb
        }

        var pickerTag: String {
            switch self {
            case .bluetooth: return "bt"
            case .usb: return "usb"
            case .other: return "other"
            }
        }
    }

    @Published private(set) var deviceID: AudioDeviceID?
    @Published private(set) var deviceName: String?
    @Published private(set) var transport: Transport = .other("Unknown")
    @Published private(set) var sampleRate: Double = 0
    @Published private(set) var bitDepth: UInt32 = 0
    @Published private(set) var formatIsFloat: Bool = false
    @Published private(set) var volumeScalar: Float = 0
    @Published private(set) var volumeDecibels: Float?
    /// dB approximation derived from the current scalar value, using the
    /// device's `kAudioDevicePropertyVolumeScalarToDecibels` curve when it
    /// publishes one and falling back to 20·log10(scalar). Useful for
    /// devices where `volumeDecibels` is read-only and stuck (wired AirPods
    /// Max delegate gain to the digital crown, so the property doesn't
    /// follow host scalar changes), but the host scalar gain is what
    /// actually attenuates the audio graph in software.
    @Published private(set) var derivedVolumeDb: Float?
    @Published private(set) var dbRange: (min: Float, max: Float)?
    @Published private(set) var canWriteDb: Bool = false
    @Published private(set) var isAirPodsMax: Bool = false
    @Published private(set) var isSupportedHeadphone: Bool = false
    @Published private(set) var supportedHeadphonePresent: Bool = false
    @Published private(set) var airPodsMaxPresent: Bool = false
    @Published private(set) var airPodsMaxOnUSB: Bool = false
    @Published private(set) var airPodsMaxBTDeviceID: AudioDeviceID?
    @Published private(set) var airPodsMaxUSBDeviceID: AudioDeviceID?
    /// Active data source as reported by the device (if it publishes one).
    /// Raw value + human-readable name + interpretation flag.
    @Published private(set) var dataSourceRaw: UInt32?
    @Published private(set) var dataSourceName: String?
    /// Device-side I/O latency in ms. AirPods Max reports ~160 ms on the
    /// BT path and ~10 ms on USB-C — the cleanest live signal for which
    /// audio path is active. `canWriteVolumeDecibels` sticks at true once
    /// USB has been plugged in during a session, so it's unreliable here.
    @Published private(set) var outputLatencyMs: Double?
    private var lastSignalKey: String = ""

    /// Heuristic threshold. BT (any codec) is always > 80 ms; USB Audio
    /// Class is consistently < 20 ms. 50 ms is a comfortable midpoint.
    static let usbLatencyThresholdMs: Double = 50

    /// Whether the device's *audio* path is the wired one right now. Used
    /// by the volume slider to decide between AVRCP-stepped vs precise dB
    /// writes, and by the Connection panel's Audio row.
    var isUsbAudioPath: Bool {
        guard let ms = outputLatencyMs, ms > 0 else { return false }
        return ms < Self.usbLatencyThresholdMs
    }

    /// One axis: how the user is currently connected to their supported
    /// headphone. Hybrid (BT control + USB-C audio gain stage) is the
    /// only mode where head tracking AND precise 1 dB volume both work,
    /// so the UI treats it as the aspirational target.
    enum SetupQuality: Equatable {
        case hybrid     // BT-labeled transport + USB-C plugged (latency < 50 ms)
        case btOnly     // BT transport, no USB-C
        case usbOnly    // USB transport, BT disabled
        case unknown    // .other transport or pre-init

        var badgeLabel: String? {
            switch self {
            case .hybrid: return "HYBRID"
            case .btOnly: return "BT ONLY"
            case .usbOnly: return "USB ONLY"
            case .unknown: return nil
            }
        }

        var pathDescription: String {
            switch self {
            case .hybrid: return "Bluetooth + USB-C"
            case .btOnly: return "Bluetooth"
            case .usbOnly: return "USB-C"
            case .unknown: return "—"
            }
        }

        var tooltip: String {
            switch self {
            case .hybrid: return "Bluetooth + USB-C — full feature set"
            case .btOnly: return "Plug USB-C for 1 dB volume steps"
            case .usbOnly: return "Enable Bluetooth for head tracking and 1 dB volume steps"
            case .unknown: return ""
            }
        }
    }

    var setupQuality: SetupQuality {
        switch transport {
        case .bluetooth: return isUsbAudioPath ? .hybrid : .btOnly
        case .usb: return .usbOnly
        case .other: return .unknown
        }
    }

    /// Names from system_profiler for paired Apple-vendor headphones, lowercased.
    /// Lets us recognise headphones the user has renamed (e.g. "dtap")
    /// without baking model substrings into the matcher.
    private var profilerHeadphoneNames: Set<String> = []

    var canSwitchTransport: Bool {
        airPodsMaxBTDeviceID != nil && airPodsMaxUSBDeviceID != nil
    }

    static func isSupportedHeadphoneName(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("airpods") || n.contains("beats fit pro")
    }

    private func matchesSupportedHeadphone(_ name: String) -> Bool {
        if Self.isSupportedHeadphoneName(name) { return true }
        return profilerHeadphoneNames.contains(name.lowercased())
    }

    private func refreshProfilerHeadphoneNames() {
        Task { [weak self] in
            let names = await SystemProfilerProbe.supportedHeadphoneDeviceNames()
            guard let self else { return }
            self.applyProfilerHeadphoneNames(names)
        }
    }

    private func applyProfilerHeadphoneNames(_ names: [String]) {
        let updated = Set(names.map { $0.lowercased() })
        guard updated != profilerHeadphoneNames else { return }
        profilerHeadphoneNames = updated
        refresh()
    }

    func switchTo(transport: Transport) {
        if FakeMode.enabled {
            self.transport = transport
            sampleRate = transport == .usb ? 48000 : 48000
            bitDepth = transport == .usb ? 24 : 16
            return
        }
        let target: AudioDeviceID?
        switch transport {
        case .bluetooth: target = airPodsMaxBTDeviceID
        case .usb: target = airPodsMaxUSBDeviceID
        case .other: target = nil
        }
        guard let id = target else { return }
        CoreAudioBridge.setDefaultOutputDevice(id)
    }

    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var pollTimer: Timer?
    private var previousDeviceIDForLog: AudioDeviceID?

    /// Hook the coordinator can install to react to transport changes
    /// (e.g. clear stale Bluetooth codec info when going wired).
    var onTransportChanged: ((Transport) -> Void)?

    private var fakeVolumeScalar: Float = 0.62
    private var fakeVolumeDb: Float = -16.0

    init() {
        if FakeMode.enabled {
            seedFakeState()
            return
        }
        refresh()
        refreshProfilerHeadphoneNames()
        installSystemListener()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshVolume() }
        }
    }

    private func seedFakeState() {
        deviceID = AudioDeviceID(0xF00D)
        deviceName = "AirPods Max (Demo)"
        transport = .bluetooth
        sampleRate = 48000
        bitDepth = 16
        formatIsFloat = false
        isAirPodsMax = true
        isSupportedHeadphone = true
        supportedHeadphonePresent = true
        airPodsMaxPresent = true
        airPodsMaxOnUSB = false
        airPodsMaxBTDeviceID = AudioDeviceID(0xF00D)
        airPodsMaxUSBDeviceID = AudioDeviceID(0xF00E)
        dbRange = (-60, 0)
        canWriteDb = true
        volumeScalar = fakeVolumeScalar
        volumeDecibels = fakeVolumeDb
        derivedVolumeDb = fakeVolumeDb
    }

    deinit {
        for (id, var address, block) in listeners {
            AudioObjectRemovePropertyListenerBlock(id, &address, nil, block)
        }
        pollTimer?.invalidate()
    }

    func refresh() {
        if FakeMode.enabled { return }
        rescanSupportedHeadphonePresence()
        guard let id = CoreAudioBridge.defaultOutputDeviceID() else {
            deviceID = nil
            deviceName = nil
            isAirPodsMax = false
            isSupportedHeadphone = false
            return
        }
        deviceID = id
        deviceName = CoreAudioBridge.deviceName(id)
        let name = deviceName ?? ""
        isAirPodsMax = name.localizedCaseInsensitiveContains("airpods max")
        isSupportedHeadphone = matchesSupportedHeadphone(name)

        if !isSupportedHeadphone && !name.isEmpty {
            // The active output isn't recognised by name — kick a profiler refresh
            // so a user-renamed pair (e.g. "dtap") gets picked up on the next pass.
            refreshProfilerHeadphoneNames()
        }

        let raw = CoreAudioBridge.transportType(id)
        let previousTransport = transport
        switch raw {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            transport = .bluetooth
        case kAudioDeviceTransportTypeUSB:
            transport = .usb
        default:
            // CoreAudio doesn't always tag wired AirPods as USB — depending
            // on the OS version and cable adapter it can come through as
            // Built-In, Aggregate, or unknown. If the device is a supported
            // wireless headphone but we're not on a BT transport, the only
            // way it could be the active output is by being plugged in.
            if isSupportedHeadphone {
                transport = .usb
            } else {
                transport = .other(CoreAudioBridge.transportLabel(raw))
            }
        }
        let prevDeviceID = previousDeviceIDForLog
        if transport != previousTransport || id != prevDeviceID {
            let rng = CoreAudioBridge.decibelRange(id)
            let currentDb = CoreAudioBridge.outputVolumeDecibels(id).map { String(format: "%+.1fdB", $0) } ?? "nil"
            let canWrite = CoreAudioBridge.canWriteVolumeDecibels(id)
            let scalar = CoreAudioBridge.outputVolumeScalar(id).map { String(format: "%.2f", $0) } ?? "nil"
            let rangeStr = rng.map { String(format: "[%+.1f, %+.1f]", $0.min, $0.max) } ?? "nil"
            print("[MoAir][Audio] device=\(name) transport=\(transport.label) raw=\(raw.map { String($0) } ?? "nil") dbRange=\(rangeStr) currentDb=\(currentDb) canWriteDb=\(canWrite) scalar=\(scalar)")
        }
        previousDeviceIDForLog = id
        // Bluetooth-side codec/AVRCP info is only meaningful while the active
        // path is Bluetooth — clear the cached snapshot when we leave BT so
        // the panel doesn't keep showing AAC-LC after switching to wired.
        onTransportChanged?(transport)

        if let format = CoreAudioBridge.virtualFormat(id) {
            sampleRate = format.mSampleRate
            bitDepth = format.mBitsPerChannel
            formatIsFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        }

        dbRange = CoreAudioBridge.decibelRange(id)
        canWriteDb = CoreAudioBridge.canWriteVolumeDecibels(id)
        refreshVolume()
        installDeviceListener(id: id)
    }

    func refreshVolume() {
        if FakeMode.enabled { return }
        guard let id = deviceID else { return }
        if let v = CoreAudioBridge.outputVolumeScalar(id) { volumeScalar = v }
        volumeDecibels = CoreAudioBridge.outputVolumeDecibels(id)
        derivedVolumeDb = derivedDecibels(forScalar: volumeScalar, deviceID: id)
        // Re-poll the capability flags on every tick. USB-C plug/unplug
        // doesn't necessarily fire the system listener (default output
        // stays the same logical AirPods Max entry), so canWriteDb /
        // dbRange would otherwise stay stale at whatever they were on the
        // last `refresh()` call. The slider's avrcpSteppedWrites flag
        // depends on canWriteDb, so this is what makes the slider snap
        // back to AVRCP stepping when the cable is pulled.
        canWriteDb = CoreAudioBridge.canWriteVolumeDecibels(id)
        dbRange = CoreAudioBridge.decibelRange(id)
        // Update the latency-based audio-path signal. Empirically:
        // AirPods Max BT = ~160 ms, USB-C = ~10 ms, threshold @ 50 ms.
        let prevIsUSB = isUsbAudioPath
        outputLatencyMs = CoreAudioBridge.outputLatencySamples(id)
            .map { Double($0) / max(1, sampleRate) * 1000.0 }
        if isUsbAudioPath != prevIsUSB {
            audioLog.info("audio path: \(self.isUsbAudioPath ? "USB" : "BT", privacy: .public) (latency=\(self.outputLatencyMs ?? -1, privacy: .public) ms)")
        }
    }

    private func derivedDecibels(forScalar scalar: Float, deviceID: AudioDeviceID) -> Float? {
        // Prefer the device's published curve — that's what macOS's own
        // Sound slider uses when it labels position in dB.
        if let v = CoreAudioBridge.scalarToDecibels(deviceID, scalar: scalar) { return v }
        // Math fallback: pure linear-amplitude. Matches dBFS at scalar=1
        // (0 dB) and asymptotes to -∞ at silence. Less accurate than the
        // device curve but more useful than nothing.
        guard scalar > 0 else { return nil }
        return 20 * log10f(scalar)
    }

    func setVolumeScalar(_ value: Float) {
        if FakeMode.enabled {
            fakeVolumeScalar = max(0, min(1, value))
            volumeScalar = fakeVolumeScalar
            fakeVolumeDb = -60 + fakeVolumeScalar * 60
            volumeDecibels = fakeVolumeDb
            derivedVolumeDb = fakeVolumeDb
            return
        }
        guard let id = deviceID else { return }
        CoreAudioBridge.setOutputVolumeScalar(id, value)
        refreshVolume()
    }

    /// Set the output volume in dB-world, using the most-faithful path the
    /// device honours: direct `setOutputVolumeDecibels` when canWriteDb,
    /// otherwise convert dB → scalar via the device's own curve (or
    /// 10^(dB/20) math fallback) and drive the scalar property. Lets the
    /// UI present a 1-dB-stepped slider/buttons even on wired AirPods Max
    /// that silently reject dB writes.
    ///
    /// After writing, `derivedVolumeDb` is set to the requested (clamped)
    /// dB so the UI reflects intent rather than the device's potentially
    /// quantized readback. On AirPods Max wired the published scalar↔dB
    /// curve isn't perfectly invertible — the round-trip drops ~½ dB per
    /// click, which makes a "1 dB" step feel like ½ dB. The 0.5 s poll
    /// timer reconciles any real drift back into the displayed value.
    func setVolumeFromDb(_ db: Float) {
        if FakeMode.enabled {
            fakeVolumeDb = max(-60, min(0, db))
            volumeDecibels = fakeVolumeDb
            fakeVolumeScalar = (fakeVolumeDb + 60) / 60
            volumeScalar = fakeVolumeScalar
            derivedVolumeDb = fakeVolumeDb
            return
        }
        guard let id = deviceID else { return }
        let lo = dbRange?.min ?? -96
        let hi = dbRange?.max ?? 0
        let clamped = max(lo, min(hi, db))
        if canWriteDb {
            CoreAudioBridge.setOutputVolumeDecibels(id, clamped)
        } else {
            let scalar = CoreAudioBridge.decibelsToScalar(id, decibels: clamped)
                ?? max(0, min(1, powf(10, clamped / 20)))
            CoreAudioBridge.setOutputVolumeScalar(id, scalar)
        }
        if let scalar = CoreAudioBridge.outputVolumeScalar(id) {
            volumeScalar = scalar
        }
        volumeDecibels = CoreAudioBridge.outputVolumeDecibels(id)
        derivedVolumeDb = clamped
    }

    /// Step the current dB by `delta`, clamped to the device's published
    /// dB range. Snaps the base to the `delta`-sized grid first so
    /// consecutive nudges compose cleanly even when the readback is
    /// slightly off-grid (see `setVolumeFromDb` comment).
    func nudgeDb(_ delta: Float) {
        let raw = derivedVolumeDb ?? volumeDecibels ?? 0
        let grid = max(0.01, abs(delta))
        let snapped = (raw / grid).rounded() * grid
        let lo = dbRange?.min ?? -96
        let hi = dbRange?.max ?? 0
        setVolumeFromDb(max(lo, min(hi, snapped + delta)))
    }

    /// Move by `delta` AVRCP buckets (1/16 of the scalar range each).
    /// For Bluetooth, this is the protocol-floor step — clicks always
    /// land on a real AVRCP-aligned scalar so the dB readback (derived
    /// via the device's own curve) is the exact dB of the current
    /// bucket, no approximation. `delta` is signed: −1 = quieter,
    /// +1 = louder.
    func nudgeAvrcpStep(_ delta: Int) {
        let current = volumeScalar
        let bucket = (current * 16).rounded() / 16
        let target = max(0, min(1, bucket + Float(delta) / 16))
        setVolumeScalar(target)
    }

    /// Convert the requested dB to a scalar via the device's own curve
    /// (or amplitude-math fallback), snap that scalar to the AVRCP
    /// 16-step grid, and write it. After the write the readback dB
    /// will land on the exact dB of the snapped bucket — useful for
    /// driving a dB-styled slider over Bluetooth.
    func setVolumeFromDbAvrcpSnapped(_ db: Float) {
        if FakeMode.enabled {
            // Fake: just emulate snap via 1 dB grid.
            setVolumeFromDb(db.rounded())
            return
        }
        guard let id = deviceID else { return }
        let lo = dbRange?.min ?? -96
        let hi = dbRange?.max ?? 0
        let clamped = max(lo, min(hi, db))
        let scalar = CoreAudioBridge.decibelsToScalar(id, decibels: clamped)
            ?? max(0, min(1, powf(10, clamped / 20)))
        let snapped = max(0, min(1, (scalar * 16).rounded() / 16))
        setVolumeScalar(snapped)
    }

    func setVolumeDecibels(_ db: Float) {
        if FakeMode.enabled {
            fakeVolumeDb = max(-60, min(0, db))
            volumeDecibels = fakeVolumeDb
            fakeVolumeScalar = (fakeVolumeDb + 60) / 60
            volumeScalar = fakeVolumeScalar
            return
        }
        guard let id = deviceID else { return }
        CoreAudioBridge.setOutputVolumeDecibels(id, db)
        refreshVolume()
    }

    func nudgeDecibels(_ delta: Float) {
        if FakeMode.enabled {
            setVolumeDecibels(fakeVolumeDb + delta)
            return
        }
        guard let id = deviceID else { return }
        if let current = CoreAudioBridge.outputVolumeDecibels(id) {
            let target = current + delta
            CoreAudioBridge.setOutputVolumeDecibels(id, target)
        } else {
            let stepScalar = delta / 60.0
            let current = CoreAudioBridge.outputVolumeScalar(id) ?? 0
            CoreAudioBridge.setOutputVolumeScalar(id, current + stepScalar)
        }
        refreshVolume()
    }

    private func rescanSupportedHeadphonePresence() {
        var maxBT: AudioDeviceID?
        var maxUSB: AudioDeviceID?
        var anySupported = false
        for id in CoreAudioBridge.allDeviceIDs() {
            guard CoreAudioBridge.hasOutputStreams(id) else { continue }
            let name = CoreAudioBridge.deviceName(id) ?? ""
            guard matchesSupportedHeadphone(name) else { continue }
            anySupported = true
            let raw = CoreAudioBridge.transportType(id)
            switch raw {
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
                if name.localizedCaseInsensitiveContains("airpods max") {
                    maxBT = id
                }
            default:
                // Non-BT supported headphone is the wired AirPods Max —
                // only the Max has a wired audio mode (Pro/4/etc. don't
                // expose USB audio class output). Don't require "Max" in
                // the name: macOS labels the wired device differently
                // across OS versions and adapter chains.
                if maxUSB == nil { maxUSB = id }
            }
        }
        airPodsMaxBTDeviceID = maxBT
        airPodsMaxUSBDeviceID = maxUSB
        airPodsMaxPresent = (maxBT != nil) || (maxUSB != nil)
        airPodsMaxOnUSB = maxUSB != nil
        supportedHeadphonePresent = anySupported
    }

    private func installSystemListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address, nil, block
        )
        if status == noErr {
            listeners.append((AudioObjectID(kAudioObjectSystemObject), address, block))
        }
    }

    private func installDeviceListener(id: AudioDeviceID) {
        // Drop any prior device-scoped listener — refresh() reinstalls on
        // every device change, so without this they accumulate and each
        // fires refreshVolume() on every volume change. System-object
        // listener (default-output-device) stays put.
        let systemID = AudioObjectID(kAudioObjectSystemObject)
        listeners.removeAll { entry in
            guard entry.0 != systemID else { return false }
            var addr = entry.1
            AudioObjectRemovePropertyListenerBlock(entry.0, &addr, nil, entry.2)
            return true
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refreshVolume() }
        }
        let status = AudioObjectAddPropertyListenerBlock(id, &address, nil, block)
        if status == noErr {
            listeners.append((id, address, block))
        }
    }
}
