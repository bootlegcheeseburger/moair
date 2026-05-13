import SwiftUI

struct VolumePanel: View {
    @EnvironmentObject var coord: AppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionLabel("VOLUME")
                Spacer()
                Text(modeLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if showsDbSlider {
                calibratedView
            } else {
                scalarView
            }
        }
    }

    private var modeLabel: String {
        if showsDbSlider { return "calibrated dB" }
        switch coord.audio.transport {
        case .bluetooth: return "16-step (BT)"
        case .usb: return "scalar"
        case .other: return ""
        }
    }

    // Precise dB writes only work on the hybrid path: CoreAudio labels
    // the device as Bluetooth but audio actually flows over the USB-C
    // gain stage. There, dB requests track cleanly to 1 dB.
    //
    // BT-only (audio over BT): AVRCP buckets, must scalar-step.
    // USB-only (BT disabled): the device publishes a degenerate dB range
    //   and non-standard scalar↔dB curve, so "1 dB" requests land at
    //   non-uniform actual dB values. Better to scalar-step too — even
    //   audible jumps regardless of dB readback.
    private var avrcpSteppedWrites: Bool {
        switch coord.audio.transport {
        case .bluetooth: return !coord.audio.isUsbAudioPath
        case .usb: return true
        case .other: return false
        }
    }

    // Bluetooth's AVRCP volume profile quantises gain to 16 steps; clicking
    // anywhere on the slider snaps to one of those. For wired/USB devices
    // (and anything that isn't BT) the host applies a software gain on the
    // audio graph and accepts continuous values, so we drop the snap to
    // match what macOS's own Sound slider does.
    private var useDiscrete16Step: Bool {
        coord.audio.transport == .bluetooth
    }

    // dB slider only when the device's dB axis is actually trustworthy —
    // i.e., the hybrid path (BT-labeled CoreAudio entry with audio
    // actually flowing over the USB-C gain stage). Everywhere else
    // (BT-only AVRCP, USB-only with its degenerate dB curve) falls back
    // to a smooth percentage slider like macOS Sound.
    private var showsDbSlider: Bool {
        coord.audio.transport == .bluetooth && coord.audio.isUsbAudioPath
    }

    // For the scalar readout: prefer the derived value (computed from the
    // current scalar via the device's own ScalarToDecibels curve, with
    // 20·log10 fallback) so the dB number tracks the slider in real time
    // even when the device's read-only volumeDecibels property is locked.
    private var displayedDb: Float? {
        coord.audio.derivedVolumeDb ?? coord.audio.volumeDecibels
    }

    private static let dbTicks: [Float] = [-32, -16, -12, -6, -2, 0]

    private var calibratedView: some View {
        // Drive the slider in dB-world. The displayed/bound value uses the
        // derived dB (scalar→dB via the device curve) so it stays accurate
        // and live even when the device's own volumeDecibels property is
        // locked. Writes go through setVolumeFromDb, which prefers a direct
        // dB write when the device accepts it and falls back to a scalar
        // conversion otherwise.
        let db = coord.audio.derivedVolumeDb ?? coord.audio.volumeDecibels ?? 0
        let range = coord.audio.dbRange ?? (-60, 0)
        let avrcpStepped = avrcpSteppedWrites
        let userStep = coord.settings.dbStep
        return VStack(alignment: .leading, spacing: 2) {
            ZStack(alignment: .center) {
                Slider(value: Binding(
                    get: { Double(db) },
                    set: { newValue in
                        let requested = Float(newValue)
                        if avrcpStepped {
                            coord.audio.setVolumeFromDbAvrcpSnapped(requested)
                        } else {
                            let snapped = (requested / userStep).rounded() * userStep
                            coord.audio.setVolumeFromDb(snapped)
                        }
                    }
                ), in: Double(range.min)...Double(range.max))
                .animation(nil, value: db)
                DbTickMarks(ticks: Self.dbTicks, range: range)
                    .allowsHitTesting(false)
            }
            DbTickLabels(ticks: Self.dbTicks, range: range)
                .frame(height: 10)
            HStack(spacing: 10) {
                Spacer()
                Text(formatDb(db))
                    .font(.system(.title2, design: .rounded).monospacedDigit().weight(.semibold))
                Button {
                    if avrcpStepped {
                        coord.audio.nudgeAvrcpStep(-1)
                    } else {
                        coord.audio.nudgeDb(-userStep)
                    }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 30))
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.borderless)
                Button {
                    if avrcpStepped {
                        coord.audio.nudgeAvrcpStep(+1)
                    } else {
                        coord.audio.nudgeDb(userStep)
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 30))
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.borderless)
            }
            .padding(.top, 2)
        }
    }

    private var scalarView: some View {
        let v = coord.audio.volumeScalar
        let nudgeStep: Float = 0.02
        return VStack(alignment: .leading, spacing: 4) {
            // Smooth scalar slider regardless of transport — for BT-only,
            // USB-only, and other non-hybrid devices. The dB readout is
            // suppressed because the device's reported dB doesn't track
            // audible attenuation faithfully in these modes.
            Slider(value: Binding(
                get: { Double(v) },
                set: { coord.audio.setVolumeScalar(Float($0)) }
            ), in: 0...1)
            HStack(spacing: 10) {
                Spacer()
                Text(String(format: "%.0f%%", v * 100))
                    .font(.system(.title2, design: .rounded).monospacedDigit().weight(.semibold))
                Button {
                    coord.audio.setVolumeScalar(max(0, v - nudgeStep))
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 30))
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.borderless)
                Button {
                    coord.audio.setVolumeScalar(min(1, v + nudgeStep))
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 30))
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.borderless)
            }
            .padding(.top, 2)
        }
    }

    private func sectionLabel(_ s: String) -> some View {
        Text(s).font(.caption.bold()).foregroundStyle(.secondary)
    }
}

func formatDb(_ db: Float) -> String {
    if db <= -99.95 { return "−∞ dB" }
    return String(format: "%.1f dB", db)
}

private let dbThumbInset: CGFloat = 11

private struct DbTickMarks: View {
    let ticks: [Float]
    let range: (min: Float, max: Float)

    private let tickHeight: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let usable = max(0, geo.size.width - dbThumbInset * 2)
            let span = max(0.0001, Double(range.max - range.min))
            ZStack {
                Rectangle()
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: 1, height: tickHeight)
                    .position(x: dbThumbInset, y: geo.size.height / 2)
                ForEach(ticks, id: \.self) { v in
                    let frac = Double(v - range.min) / span
                    let x = dbThumbInset + CGFloat(frac) * usable
                    Rectangle()
                        .fill(Color.secondary.opacity(0.45))
                        .frame(width: 1, height: tickHeight)
                        .position(x: x, y: geo.size.height / 2)
                }
            }
        }
    }
}

private struct DbTickLabels: View {
    let ticks: [Float]
    let range: (min: Float, max: Float)

    private static let unlabeled: Set<Int> = [-16, -6]

    var body: some View {
        GeometryReader { geo in
            let usable = max(0, geo.size.width - dbThumbInset * 2)
            let span = max(0.0001, Double(range.max - range.min))
            ZStack {
                label("−∞", x: dbThumbInset, in: geo.size)
                ForEach(ticks, id: \.self) { v in
                    if let text = format(v) {
                        let frac = Double(v - range.min) / span
                        let x = dbThumbInset + CGFloat(frac) * usable
                        label(text, x: x, in: geo.size)
                    }
                }
            }
        }
    }

    private func label(_ text: String, x: CGFloat, in size: CGSize) -> some View {
        Text(text)
            .font(.system(size: 8))
            .foregroundStyle(.secondary)
            .fixedSize()
            .position(x: x, y: size.height / 2)
    }

    private func format(_ v: Float) -> String? {
        if Self.unlabeled.contains(Int(v)) { return nil }
        return v == 0 ? "0" : "−\(Int(-v))"
    }
}
