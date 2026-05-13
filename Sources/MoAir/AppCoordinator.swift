import Foundation
import Combine
import AppKit
import SwiftUI

@MainActor
final class AppCoordinator: ObservableObject {
    enum ConnectionStatus: Equatable {
        case ready
        case btDisabledForTracking
        case noDevice
        case airpodsAvailableNotSelected
        case airpodsOffHead
        case airpodsDisconnected
        case motionUnsupported
        case motionDenied

        var iconName: String {
            switch self {
            case .ready: return "headphones.circle.fill"
            case .btDisabledForTracking: return "dot.radiowaves.up.forward"
            case .noDevice: return "speaker.slash"
            case .airpodsAvailableNotSelected: return "headphones.slash"
            case .airpodsOffHead: return "headphones.slash"
            case .airpodsDisconnected: return "headphones"
            case .motionUnsupported: return "exclamationmark.triangle"
            case .motionDenied: return "lock.shield"
            }
        }

        var iconColor: Color {
            switch self {
            case .ready: return .green
            case .btDisabledForTracking: return .blue
            case .noDevice, .airpodsAvailableNotSelected: return .secondary
            case .airpodsOffHead: return .orange
            case .airpodsDisconnected: return .gray
            case .motionUnsupported: return .orange
            case .motionDenied: return .red
            }
        }

        var headline: String {
            switch self {
            case .ready: return "Ready"
            case .btDisabledForTracking: return "Enable Bluetooth for head tracking"
            case .noDevice: return "No audio output"
            case .airpodsAvailableNotSelected: return "Headphones not selected"
            case .airpodsOffHead: return "Headphones removed"
            case .airpodsDisconnected: return "Headphones disconnected"
            case .motionUnsupported: return "Head tracking unavailable"
            case .motionDenied: return "Motion access denied"
            }
        }

        func subhead(deviceName: String?) -> String {
            switch self {
            case .ready:
                return ""
            case .btDisabledForTracking:
                return "Head motion streams over Bluetooth. Turn it back on in Control Center to resume tracking."
            case .noDevice:
                return "No active audio output."
            case .airpodsAvailableNotSelected:
                return "Switch system output to your AirPods or Beats Fit Pro."
            case .airpodsOffHead:
                return "Put them back on to resume head tracking."
            case .airpodsDisconnected:
                return "Connect AirPods 3 / Pro / 4 ANC / Max or Beats Fit Pro."
            case .motionUnsupported:
                return "Requires macOS 14+ with a head-tracking-capable headphone."
            case .motionDenied:
                return "Motion access is denied for MoAir."
            }
        }

        /// HT toggle can only start tracking in the fully ready state.
        var canStartTracking: Bool { self == .ready }
        /// Volume can be controlled in both fully ready AND the HT-gated
        /// state — the user still has headphones connected, they just
        /// can't track head motion.
        var canControlVolume: Bool { self == .ready || self == .btDisabledForTracking }
    }

    private static let nearbyAirPodsWindow: TimeInterval = 30

    var connectionStatus: ConnectionStatus {
        if headTracker.state == .unsupported { return .motionUnsupported }
        if headTracker.state == .denied { return .motionDenied }
        // "Removed from head" = motion stream stopped (AirPods sleep on
        // removal) but the device is still in the BT/audio list. If the
        // device left the list too, it's a real BT disconnect.
        if headTracker.state == .stoppedByDisconnect &&
           (audio.airPodsMaxPresent || audio.supportedHeadphonePresent) {
            return .airpodsOffHead
        }
        if audio.isSupportedHeadphone {
            // USB-only (BT disabled) keeps volume working but cannot
            // stream motion. Route to a dedicated status so the HT panel
            // gets the inline coaching message and the toggle stays off.
            return audio.setupQuality == .usbOnly ? .btDisabledForTracking : .ready
        }
        if audio.supportedHeadphonePresent || audio.airPodsMaxPresent || airpodsRecentlySeen {
            return .airpodsAvailableNotSelected
        }
        if audio.deviceID == nil { return .noDevice }
        return .airpodsDisconnected
    }

    private var airpodsRecentlySeen: Bool {
        guard let last = battery.lastUpdate else { return false }
        return Date().timeIntervalSince(last) < Self.nearbyAirPodsWindow
    }


    let settings: AppSettings
    let headTracker: HeadTracker
    let oscBridge: OSCBridge
    let audio: AudioController
    let battery: ContinuityScanner
    let codec: CodecSniffer
    let latency: LatencyEstimator

    @Published private(set) var isFlashingRecalibration: Bool = false

    private var cancellables = Set<AnyCancellable>()
    private var recalibrationFlashTask: Task<Void, Never>?
    private var optionClickMonitor: Any?
    /// Set when the head tracker transitions into `.stoppedByDisconnect`
    /// and cleared when it next reaches `.streaming` (or `.idle` from a
    /// user-initiated stop). Used to suppress the auto-recalibration
    /// flash on auto-restart-after-disconnect — those reticle blinks
    /// look like phantom flashes when the user is just taking the cans
    /// off, since the motion manager can briefly re-enter `.streaming`
    /// before settling.
    private var sawDisconnectSinceLastStream: Bool = false

    init() {
        self.settings = AppSettings()
        self.headTracker = HeadTracker()
        self.oscBridge = OSCBridge()
        self.audio = AudioController()
        self.battery = ContinuityScanner()
        self.codec = CodecSniffer()
        self.latency = LatencyEstimator()

        oscBridge.settings = settings.oscSettings
        latency.bind(audio: audio, head: headTracker, osc: oscBridge)

        audio.onTransportChanged = { [weak self] transport in
            guard let self else { return }
            if transport != .bluetooth {
                self.codec.clearCurrent()
            }
        }

        headTracker.onSample = { [weak self] sample in
            guard let self else { return }
            Task { @MainActor in
                self.oscBridge.send(sample)
            }
        }

        settings.$oscHost.combineLatest(settings.$oscPortText, settings.$addressPrefix, settings.$preset)
            .sink { [weak self] _, _, _, _ in
                self?.oscBridge.settings = self?.settings.oscSettings ?? .darPreset
            }
            .store(in: &cancellables)

        // Push the post-processing knobs into the head tracker whenever any
        // of them changes. Combine doesn't ship a `CombineLatest5`, so we
        // pair the four 0...1 dials with the signed sensitivity slider via
        // a nested combineLatest and reassemble the struct from the new
        // values. Reading from publisher emissions (not `settings.foo`)
        // dodges the @Published willSet / didSet timing question.
        let dials = Publishers.CombineLatest4(
            settings.$jitter,
            settings.$deadSpotYaw,
            settings.$deadSpotPitch,
            settings.$deadSpotRoll
        )
        dials.combineLatest(settings.$sensitivity)
            .sink { [weak self] (dialValues, sens) in
                let (j, dy, dp, dr) = dialValues
                self?.headTracker.postProcessing = HeadTracker.PostProcessing(
                    jitter: j,
                    deadSpotYaw: dy,
                    deadSpotPitch: dp,
                    deadSpotRoll: dr,
                    sensitivity: sens
                )
            }
            .store(in: &cancellables)

        // Auto-recalibrate ~500ms after a *user-initiated* transition into
        // .streaming so the user always faces "forward" without an explicit
        // ⌥-click. The delay lets CoreMotion settle on a stable sample
        // before we capture it as the reference; quickRecalibrate also
        // gives the flash so the recal is visible.
        //
        // Skipped when the previous state was `.stoppedByDisconnect`
        // (tracked across intermediate states via sawDisconnectSinceLastStream)
        // so taking cans off — which can briefly re-enter `.streaming`
        // mid-disconnect — doesn't ghost-flash the reticle.
        headTracker.$state
            .removeDuplicates()
            .sink { [weak self] new in
                guard let self else { return }
                switch new {
                case .stoppedByDisconnect:
                    self.sawDisconnectSinceLastStream = true
                case .idle:
                    // User explicitly stopped; the next start is intentional.
                    self.sawDisconnectSinceLastStream = false
                case .streaming:
                    let suppress = self.sawDisconnectSinceLastStream
                    self.sawDisconnectSinceLastStream = false
                    guard !suppress else { return }
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        _ = self?.quickRecalibrate()
                    }
                default:
                    break
                }
            }
            .store(in: &cancellables)

        republish(settings)
        republish(headTracker)
        republish(oscBridge)
        republish(audio)
        republish(battery)
        republish(codec)
        republish(latency)

        codec.start()
        do {
            try oscBridge.start()
        } catch {
            print("[MoAir] OSC start failed: \(error)")
        }
        if settings.streamingOnLaunch || FakeMode.enabled {
            headTracker.start()
        }

        installOptionClickMonitor()
    }

    /// Intercept ⌥-clicks on the menu-bar item *before* SwiftUI's
    /// `MenuBarExtra` opens its popover, so the user gets the recalibration
    /// + reticle flash without the panel ever appearing or the status
    /// button painting its pressed state. Returning `nil` from a local
    /// `NSEvent` monitor discards the click before normal dispatch.
    private func installOptionClickMonitor() {
        optionClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            guard event.modifierFlags.contains(.option) else { return event }
            guard let window = event.window else { return event }
            // Match by window class — `MenuBarExtra` is backed by a private
            // `NSStatusBarWindow` subclass, so we can't compare against a
            // public type. The class name is stable across recent macOS.
            let className = String(describing: type(of: window))
            guard className.contains("StatusBar") else { return event }
            Task { @MainActor [weak self] in
                _ = self?.quickRecalibrate()
            }
            return nil
        }
    }

    deinit {
        if let monitor = optionClickMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    func toggleStreaming() {
        switch headTracker.state {
        case .streaming, .waitingForPermission:
            headTracker.stop()
        default:
            headTracker.start()
        }
    }

    func reZero() {
        headTracker.reZero()
    }

    /// Recalibrate without opening the menu, and flash the menubar icon
    /// (reticle blink x2) so the user sees the action took effect. Invoked
    /// by Option-clicking the menu-bar item. No-op when not streaming —
    /// recalibrating zero against a zero quaternion is meaningless and the
    /// flash would be misleading.
    func quickRecalibrate() -> Bool {
        guard headTracker.state == .streaming else { return false }
        headTracker.reZero()
        recalibrationFlashTask?.cancel()
        recalibrationFlashTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let onMs: UInt64 = 110
            let offMs: UInt64 = 90
            for i in 0..<2 {
                self.isFlashingRecalibration = true
                try? await Task.sleep(nanoseconds: onMs * 1_000_000)
                if Task.isCancelled { self.isFlashingRecalibration = false; return }
                self.isFlashingRecalibration = false
                if i < 1 {
                    try? await Task.sleep(nanoseconds: offMs * 1_000_000)
                    if Task.isCancelled { return }
                }
            }
        }
        return true
    }

    private func republish<O: ObservableObject>(_ child: O) where O.ObjectWillChangePublisher == ObservableObjectPublisher {
        child.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }
}
