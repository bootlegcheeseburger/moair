import SwiftUI

struct ConnectionPanel: View {
    @EnvironmentObject var coord: AppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                sectionLabel("CONNECTION")
                if let badge = coord.audio.setupQuality.badgeLabel {
                    Text(badge)
                        .font(.caption2.bold())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(setupBadgeColor.opacity(0.2), in: Capsule())
                        .foregroundStyle(setupBadgeColor)
                        .help(coord.audio.setupQuality.tooltip)
                }
                Spacer()
                if coord.audio.canSwitchTransport {
                    transportPicker
                }
            }
            row("Path", coord.audio.setupQuality.pathDescription)
            row("Format", formatString)
            if coord.audio.transport == .bluetooth, let codec = coord.codec.current?.codec {
                row("Codec", codecString(codec))
            }
            if let battery = coord.battery.batteryPercent {
                row("Battery", batteryString(battery))
            }
            if let rssi = coord.battery.lastSeenRSSI {
                row("RSSI", "\(rssi) dBm")
            }
            audioLatencyRows
            if coord.headTracker.state == .streaming {
                metricRow("Tracking Lag",
                          number: String(format: "%.1f", coord.latency.headTrackingPipelineMs),
                          unit: " ms")
                let interval = coord.latency.oscSendIntervalMs
                let hz = interval > 0 ? 1000.0 / interval : 0
                metricRow("OSC Rate",
                          number: String(format: "%.0f", hz),
                          unit: " Hz")
            }
        }
    }

    /// Three time-base readouts of the audio latency on consecutive lines.
    /// The label is only on the first row — the frames/samples rows are
    /// labelless subsets, grouped by a slightly tighter VStack spacing
    /// than the rest of the panel so the relationship reads visually.
    @ViewBuilder
    private var audioLatencyRows: some View {
        if let audio = coord.latency.audio {
            let ms = audio.totalMilliseconds
            let frames24 = ms * 24.0 / 1000.0
            let sr = coord.audio.sampleRate
            VStack(alignment: .leading, spacing: 2) {
                metricRow("Audio Latency",
                          number: String(format: "%.1f", ms),
                          unit: " ms")
                metricRow("",
                          number: String(format: "%.1f", frames24),
                          unit: " fr @ 24 fps")
                if sr > 0 {
                    let samples = Int((ms * sr / 1000.0).rounded())
                    let kHz = sr / 1000.0
                    let kHzText = kHz.truncatingRemainder(dividingBy: 1) == 0
                        ? String(format: "%.0f kHz", kHz)
                        : String(format: "%.1f kHz", kHz)
                    metricRow("",
                              number: "\(samples)",
                              unit: " smpls @ \(kHzText)")
                }
            }
        }
    }

    /// Like `row`, but splits the value into a bright number and a dim
    /// unit/qualifier suffix so units read as accents rather than data.
    private func metricRow(_ k: String, number: String, unit: String) -> some View {
        HStack {
            Text(k).font(.caption).foregroundStyle(.secondary)
            Spacer()
            (Text(number) + Text(unit).foregroundStyle(.secondary))
                .font(.caption.monospacedDigit())
                .lineLimit(1)
        }
    }

    private var transportPicker: some View {
        let current: AudioController.Transport = coord.audio.transport
        return Picker("", selection: Binding(
            get: { current.pickerTag },
            set: { tag in
                switch tag {
                case "bt": coord.audio.switchTo(transport: .bluetooth)
                case "usb": coord.audio.switchTo(transport: .usb)
                default: break
                }
            }
        )) {
            Text("BT").tag("bt")
            Text("USB").tag("usb")
        }
        .pickerStyle(.segmented)
        .controlSize(.mini)
        .labelsHidden()
        .frame(width: 90)
    }

    private var formatString: String {
        let sr = coord.audio.sampleRate
        let bits = coord.audio.bitDepth
        guard sr > 0 else { return "—" }
        let kind = coord.audio.formatIsFloat ? "float" : "int"
        return String(format: "%.1f kHz · %d-bit %@", sr / 1000, bits, kind)
    }

    private func codecString(_ codec: String) -> String {
        var parts = [codec]
        if let br = coord.codec.current?.bitrateKbps {
            parts.append("\(br) kbps")
        }
        return parts.joined(separator: " · ")
    }

    private func batteryString(_ percent: Int) -> String {
        var s = "\(percent)%"
        if coord.battery.isCharging { s += " ⚡" }
        if coord.battery.isInCase { s += " (in case)" }
        return s
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(v).font(.caption.monospacedDigit())
        }
    }

    /// Capsule tint for the setup-quality badge in the section header.
    /// HYBRID is green (target state); BT-only is blue (partial — adds
    /// HT but loses precise dB); USB-only is orange (partial — loses HT
    /// and precise dB).
    private var setupBadgeColor: Color {
        switch coord.audio.setupQuality {
        case .hybrid: return .green
        case .btOnly: return .blue
        case .usbOnly: return .orange
        case .unknown: return .secondary
        }
    }

    private func sectionLabel(_ s: String) -> some View {
        Text(s).font(.caption.bold()).foregroundStyle(.secondary)
    }
}
