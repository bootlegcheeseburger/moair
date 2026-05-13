import Foundation
import Combine

@MainActor
final class AppSettings: ObservableObject {
    enum Preset: String, CaseIterable, Identifiable {
        case dar
        case mach1
        case virtuoso
        case asaf
        case nx
        case custom

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .dar: return "DAR"
            case .mach1: return "Mach1"
            case .virtuoso: return "Virtuoso"
            case .asaf: return "ASAF"
            case .nx: return "Nx"
            case .custom: return "Custom"
            }
        }

        /// Literal address-prefix prepended by the encoder when the user
        /// hasn't entered an override. Currently only Mach1 has a non-empty
        /// default; DAR/ASAF/Nx use fixed addresses inside their
        /// encoders and ignore the prefix.
        var defaultPrefix: String {
            switch self {
            case .dar: return OSCSettings.darPreset.addressPrefix
            case .mach1: return OSCSettings.mach1Preset.addressPrefix
            case .virtuoso: return OSCSettings.virtuosoPreset.addressPrefix
            case .asaf: return OSCSettings.asafPreset.addressPrefix
            case .nx: return OSCSettings.nxPreset.addressPrefix
            case .custom: return ""
            }
        }

        /// Greyed-out placeholder shown in the Prefix field so the user can
        /// see what address namespace the active preset uses. Descriptive,
        /// not literal - typing replaces the override, but the display gives
        /// a hint of what addresses will go out.
        var prefixHint: String {
            switch self {
            case .dar: return "/ypr, /quaternion"
            case .mach1: return "/m1"
            case .virtuoso: return "/yaw, /pitch, /roll"
            case .asaf: return "/HeadPose"
            case .nx: return "/nxosc/quaternion"
            case .custom: return "(optional)"
            }
        }

        /// UDP port the preset suggests when the user hasn't entered an
        /// override. Drives the greyed-out placeholder in SettingsView and
        /// is the fallback for `effectivePort`.
        var defaultPort: UInt16 {
            switch self {
            case .dar: return OSCSettings.darPreset.port
            case .mach1: return OSCSettings.mach1Preset.port
            case .virtuoso: return OSCSettings.virtuosoPreset.port
            case .asaf: return OSCSettings.asafPreset.port
            case .nx: return OSCSettings.nxPreset.port
            case .custom: return OSCSettings.darPreset.port
            }
        }
    }

    /// Default host used when no global override has been entered.
    static let defaultHost = "127.0.0.1"

    @Published var preset: Preset {
        didSet {
            guard oldValue != preset else { return }
            UserDefaults.standard.set(preset.rawValue, forKey: Keys.preset)
            // Restore whatever the user had typed last time on this preset.
            addressPrefix = prefixOverrides[preset.rawValue] ?? ""
            oscPortText = portOverrides[preset.rawValue] ?? ""
        }
    }
    /// Global host override (applies across all presets). Empty = use
    /// `AppSettings.defaultHost` ("127.0.0.1").
    @Published var oscHost: String { didSet { UserDefaults.standard.set(oscHost, forKey: Keys.host) } }
    /// Per-preset port override held as text so empty state is representable.
    /// Empty = use the active preset's `defaultPort`.
    @Published var oscPortText: String {
        didSet {
            let trimmed = oscPortText.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                portOverrides.removeValue(forKey: preset.rawValue)
            } else {
                portOverrides[preset.rawValue] = trimmed
            }
            UserDefaults.standard.set(portOverrides, forKey: Keys.portOverrides)
        }
    }
    @Published var addressPrefix: String {
        didSet {
            if addressPrefix.isEmpty {
                prefixOverrides.removeValue(forKey: preset.rawValue)
            } else {
                prefixOverrides[preset.rawValue] = addressPrefix
            }
            UserDefaults.standard.set(prefixOverrides, forKey: Keys.prefixOverrides)
        }
    }

    /// Per-preset prefix overrides keyed by Preset.rawValue. Each preset
    /// remembers its own typed value across preset switches so the user
    /// doesn't have to re-enter it.
    private var prefixOverrides: [String: String]
    /// Per-preset port overrides (stored as text strings for symmetry with
    /// prefix). Same persistence model: each preset remembers its own value.
    private var portOverrides: [String: String]
    @Published var streamingOnLaunch: Bool { didSet { UserDefaults.standard.set(streamingOnLaunch, forKey: Keys.autoStart) } }
    @Published var dbStep: Float { didSet { UserDefaults.standard.set(dbStep, forKey: Keys.dbStep) } }
    /// Set true once the user has clicked Agree on the inline EULA gate.
    /// The gate replaces the normal menu content until accepted.
    @Published var eulaAccepted: Bool { didSet { UserDefaults.standard.set(eulaAccepted, forKey: Keys.eulaAccepted) } }

    // Post-processing applied to the calibrated head orientation before it's
    // displayed and sent over OSC. All four values are 0...1; the meaningful
    // amplitudes/thresholds in degrees live in `HeadTracker.PostProcessing`.
    @Published var jitter: Double { didSet { UserDefaults.standard.set(jitter, forKey: Keys.jitter) } }
    @Published var deadSpotYaw: Double { didSet { UserDefaults.standard.set(deadSpotYaw, forKey: Keys.deadSpotYaw) } }
    @Published var deadSpotPitch: Double { didSet { UserDefaults.standard.set(deadSpotPitch, forKey: Keys.deadSpotPitch) } }
    @Published var deadSpotRoll: Double { didSet { UserDefaults.standard.set(deadSpotRoll, forKey: Keys.deadSpotRoll) } }

    /// Global sensitivity knob in [-1, +1] with 0 as the neutral default.
    /// Mapped to a 0…2× multiplier inside `HeadTracker.PostProcessing`,
    /// so -1 mutes all motion and +1 doubles it. Stored as the signed
    /// slider value so "default → 0" is the natural UserDefaults zero.
    @Published var sensitivity: Double { didSet { UserDefaults.standard.set(sensitivity, forKey: Keys.sensitivity) } }

    private enum Keys {
        static let preset = "osc.preset"
        static let host = "osc.host"
        static let portOverrides = "osc.portOverrides"
        static let prefixOverrides = "osc.prefixOverrides"
        static let autoStart = "app.autoStart"
        static let dbStep = "audio.dbStep"
        static let eulaAccepted = "app.eulaAccepted"
        static let jitter = "tracking.jitter"
        static let deadSpotYaw = "tracking.deadSpot.yaw"
        static let deadSpotPitch = "tracking.deadSpot.pitch"
        static let deadSpotRoll = "tracking.deadSpot.roll"
        static let sensitivity = "tracking.sensitivity"
    }

    /// Out-of-the-box values for the post-processing controls. Single
    /// source of truth so `register(defaults:)` and the ⌥-click reset on
    /// each dial/slider can never drift. Sensitivity is the signed raw
    /// slider value; -0.30 maps to a 0.70× motion multiplier (mild
    /// attenuation), which feels stable on AirPods Max motion data.
    enum Defaults {
        static let jitter: Double = 0.75
        static let deadSpot: Double = 0.10
        static let sensitivity: Double = -0.30
    }

    init() {
        let defaults = UserDefaults.standard
        // Registered fallbacks — used only when the user hasn't explicitly
        // set the key. Once any slider is touched, that value persists.
        defaults.register(defaults: [
            Keys.jitter: Defaults.jitter,
            Keys.deadSpotYaw: Defaults.deadSpot,
            Keys.deadSpotPitch: Defaults.deadSpot,
            Keys.deadSpotRoll: Defaults.deadSpot,
            Keys.sensitivity: Defaults.sensitivity,
        ])
        let storedPreset = Preset(rawValue: defaults.string(forKey: Keys.preset) ?? "") ?? .dar
        self.preset = storedPreset
        self.oscHost = defaults.string(forKey: Keys.host) ?? ""
        let prefOverrides = (defaults.dictionary(forKey: Keys.prefixOverrides) as? [String: String]) ?? [:]
        self.prefixOverrides = prefOverrides
        self.addressPrefix = prefOverrides[storedPreset.rawValue] ?? ""
        let prtOverrides = (defaults.dictionary(forKey: Keys.portOverrides) as? [String: String]) ?? [:]
        self.portOverrides = prtOverrides
        self.oscPortText = prtOverrides[storedPreset.rawValue] ?? ""
        self.streamingOnLaunch = defaults.bool(forKey: Keys.autoStart)
        let storedStep = defaults.float(forKey: Keys.dbStep)
        self.dbStep = storedStep > 0 ? storedStep : 1.0
        self.eulaAccepted = defaults.bool(forKey: Keys.eulaAccepted)
        self.jitter = clamp01(defaults.double(forKey: Keys.jitter))
        self.deadSpotYaw = clamp01(defaults.double(forKey: Keys.deadSpotYaw))
        self.deadSpotPitch = clamp01(defaults.double(forKey: Keys.deadSpotPitch))
        self.deadSpotRoll = clamp01(defaults.double(forKey: Keys.deadSpotRoll))
        self.sensitivity = max(-1, min(1, defaults.double(forKey: Keys.sensitivity)))
    }

    /// Host actually sent over OSC: global user override if non-empty,
    /// otherwise the app-wide `defaultHost`.
    var effectiveHost: String {
        let trimmed = oscHost.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? Self.defaultHost : trimmed
    }

    /// Port actually sent over OSC: per-preset override if a valid integer,
    /// otherwise the active preset's `defaultPort`.
    var effectivePort: UInt16 {
        if let n = UInt16(oscPortText.trimmingCharacters(in: .whitespaces)), n > 0 {
            return n
        }
        return preset.defaultPort
    }

    /// Prefix actually sent over OSC: explicit user override if non-empty,
    /// otherwise the active preset's default. Encoders see this via
    /// `oscSettings.addressPrefix`.
    var effectivePrefix: String {
        addressPrefix.isEmpty ? preset.defaultPrefix : addressPrefix
    }

    var oscSettings: OSCSettings {
        OSCSettings(host: effectiveHost, port: effectivePort, addressPrefix: effectivePrefix, schema: schemaForPreset)
    }

    private var schemaForPreset: OSCSchema {
        switch preset {
        case .dar: return .dar
        case .virtuoso: return .virtuoso
        case .asaf: return .asaf
        case .nx: return .nx
        case .mach1, .custom: return .mach1
        }
    }
}

private func clamp01(_ v: Double) -> Double { max(0, min(1, v)) }
