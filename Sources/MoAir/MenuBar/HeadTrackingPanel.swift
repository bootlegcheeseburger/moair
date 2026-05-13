import SwiftUI

struct HeadTrackingPanel: View {
    @EnvironmentObject var coord: AppCoordinator
    @State private var showAdvanced: Bool = false

    private var isStreaming: Bool {
        coord.headTracker.state == .streaming || coord.headTracker.state == .waitingForPermission
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                sectionLabel("HEAD TRACKING")
                if let badge = stateBadge {
                    Text(badge.label)
                        .font(.caption2.bold())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(badge.color.opacity(0.2), in: Capsule())
                        .foregroundStyle(badge.color)
                }
                Spacer()
                if coord.headTracker.state == .streaming {
                    Button {
                        // Suppress implicit animations on the layout
                        // collapse so the volume slider above doesn't
                        // briefly interpolate its bound value while the
                        // panel re-flows.
                        var t = Transaction()
                        t.disablesAnimations = true
                        withTransaction(t) { showAdvanced.toggle() }
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Show advanced motion shaping (jitter / dead-spots)")
                    .tint(showAdvanced ? .accentColor : nil)
                }
                Button {
                    _ = coord.quickRecalibrate()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "scope")
                        Text("RECAL")
                            .font(.caption2.bold())
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Re-zero current orientation as forward + flash menu-bar icon (same as ⌥-click on the menu-bar)")
                .disabled(coord.headTracker.state != .streaming)
                Toggle("", isOn: Binding(
                    get: { isStreaming },
                    set: { _ in coord.toggleStreaming() }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(!coord.connectionStatus.canStartTracking)
            }
            if isStreaming {
                if coord.headTracker.totalSamples == 0 {
                    waitingMessage
                } else {
                    // Bind to `displayedStable` so the YPR readout doesn't
                    // dance around with simulated jitter — calibration is
                    // easier when the numbers sit still. The OSC stream
                    // still uses the jitter-laden `displayed`.
                    let stable = coord.headTracker.displayedStable
                    HStack(alignment: .top, spacing: 16) {
                        axisColumn(name: "Yaw",
                                   icon: "arrow.left.and.right",
                                   value: stable.yawDegrees,
                                   deadSpot: settingsBinding(\.deadSpotYaw))
                        axisColumn(name: "Pitch",
                                   icon: "arrow.up.and.down",
                                   value: stable.pitchDegrees,
                                   deadSpot: settingsBinding(\.deadSpotPitch))
                        axisColumn(name: "Roll",
                                   icon: "arrow.triangle.2.circlepath",
                                   value: stable.rollDegrees,
                                   deadSpot: settingsBinding(\.deadSpotRoll))
                        if showAdvanced {
                            jitterColumn
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if showAdvanced {
                        sensitivitySlider
                            .padding(.top, 4)
                    }
                    Text(String(format: "%.1f Hz", coord.headTracker.effectiveHz))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let err = coord.headTracker.lastError {
                    Text("Motion error: \(err)")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                if case .error(let msg) = coord.oscBridge.state {
                    Text("OSC error: \(msg)")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                if coord.headTracker.state == .streaming {
                    Text("⌥-click the menu-bar icon to quickly recalibrate.")
                        .font(.caption2.italic())
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 2)
                }
            }
        }
        // Disable implicit layout/transition animations on showAdvanced
        // collapse — without this, the conditional `jitterColumn` /
        // `sensitivitySlider` removal triggers a default transition that
        // briefly resizes the menubar window, which visually drops the
        // volume slider above before snapping back.
        .animation(nil, value: showAdvanced)
    }

    private var stateBadge: (label: String, color: Color)? {
        switch coord.headTracker.state {
        case .streaming: return ("LIVE", .green)
        case .waitingForPermission: return ("WAIT", .yellow)
        case .denied: return ("DENIED", .red)
        case .unsupported: return ("N/A", .gray)
        case .stoppedByDisconnect: return ("DROPPED", .orange)
        case .idle: return nil
        }
    }

    private var waitingMessage: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(messageHeadline)
                .font(.caption)
            Text(messageSub)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var messageHeadline: String {
        switch coord.headTracker.state {
        case .denied: return "Motion access denied"
        case .unsupported: return "Head tracking unavailable on this Mac"
        case .stoppedByDisconnect: return "Lost motion connection"
        default: return "Waiting for motion data…"
        }
    }

    private var messageSub: String {
        switch coord.headTracker.state {
        case .denied: return "Motion & Fitness access is required."
        case .unsupported: return "Requires macOS 14+ with a head-tracking-capable headphone."
        case .stoppedByDisconnect: return "Headphones may have switched to another device or gone idle."
        default: return "Try playing audio — some headphones only stream motion while audio is flowing."
        }
    }

    /// One YPR axis column. Displays the calibrated angle, plus — when the
    /// advanced sliders are revealed — a small dead-spot dial directly
    /// underneath so the dead-zone control is visually paired with its axis.
    private func axisColumn(name: String,
                            icon: String,
                            value: Double,
                            deadSpot: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                Text(name)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            Text(String(format: "%+.1f°", value))
                .font(.system(.title3, design: .monospaced).weight(.medium))
                .frame(minWidth: 70, alignment: .leading)
            if showAdvanced {
                CircularDial(value: deadSpot,
                             size: 30,
                             label: "DEAD SPOT",
                             defaultValue: AppSettings.Defaults.deadSpot)
                    .frame(maxWidth: 70, alignment: .leading)
            }
        }
    }

    /// Global jitter dial. Mirrors the axisColumn structure (label, value,
    /// dial) so the dial sits on the same vertical baseline as the per-axis
    /// dead-spots — otherwise the jitter dial floats higher than the row
    /// of dead-spot dials and the layout looks off.
    private var jitterColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Jitter").font(.caption2).foregroundStyle(.secondary)
            Text("\(Int((coord.settings.jitter * 100).rounded()))%")
                .font(.system(.title3, design: .monospaced).weight(.medium))
                .frame(minWidth: 70, alignment: .leading)
            if showAdvanced {
                CircularDial(value: settingsBinding(\.jitter),
                             size: 30,
                             label: "ALL",
                             defaultValue: AppSettings.Defaults.jitter)
                    .frame(maxWidth: 70, alignment: .leading)
            }
        }
    }

    /// Big global-sensitivity slider, full-width. Slider raw is [-1, +1];
    /// motion multiplier = 1 + raw, so 0× / 1× / 2× span left → right.
    /// Two magnetic detents: the centre at 1× (neutral pass-through), and
    /// the app default at 0.70× (mild attenuation, the recommended start
    /// point for AirPods motion data).
    private var sensitivitySlider: some View {
        let raw = settingsBinding(\.sensitivity)
        let defaultRaw = AppSettings.Defaults.sensitivity
        let defaultMult = 1.0 + defaultRaw
        // ±0.03 of the slider's half-range is wide enough to feel without
        // being so wide that nearby values become unreachable.
        let detented = Binding(
            get: { raw.wrappedValue },
            set: { v in
                let snapZone = 0.03
                if abs(v) < snapZone {
                    raw.wrappedValue = 0
                } else if abs(v - defaultRaw) < snapZone {
                    raw.wrappedValue = defaultRaw
                } else {
                    raw.wrappedValue = v
                }
            }
        )
        let multiplier = 1.0 + raw.wrappedValue
        // 0× sits at the left edge (raw = -1) and 2× at the right (raw = +1),
        // so the default at raw -0.30 lands at (default - (-1)) / 2 = 0.35
        // of the slider's width.
        let defaultPosFraction: Double = (defaultRaw + 1.0) / 2.0
        return VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text("Sensitivity")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.2f×", multiplier))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(multiplier == 1.0 ? .secondary : .primary)
                    .onTapGesture(count: 2) {
                        raw.wrappedValue = 0
                    }
                    .help("Double-click to reset to 1.00× (centre)")
            }
            Slider(value: detented, in: -1...1)
                .controlSize(.small)
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    Text("0×")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("2×")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Text("1×")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .position(x: geo.size.width * 0.5, y: 6)
                    Text(String(format: "%.2f× default", defaultMult))
                        .font(.caption2.bold())
                        .foregroundStyle(Color.accentColor)
                        .position(x: geo.size.width * CGFloat(defaultPosFraction), y: 6)
                }
            }
            .frame(height: 12)
        }
    }

    /// AppSettings is an @Published-driven ObservableObject reached through
    /// the coordinator, but it isn't itself an @ObservedObject in this
    /// view — so `$coord.settings.foo` is unavailable. This helper builds
    /// the equivalent Binding by hand so the dials stay two-way bound.
    private func settingsBinding(_ keyPath: ReferenceWritableKeyPath<AppSettings, Double>) -> Binding<Double> {
        Binding(
            get: { coord.settings[keyPath: keyPath] },
            set: { coord.settings[keyPath: keyPath] = $0 }
        )
    }

    private func sectionLabel(_ s: String) -> some View {
        Text(s).font(.caption.bold()).foregroundStyle(.secondary)
    }
}

/// Compact circular value-knob, 0...1, vertical drag to adjust.
///
/// The control intentionally avoids angular dragging (which gets fiddly at
/// small sizes inside a menu-bar popover); a 100pt vertical drag spans the
/// full range. Display: ring outline + accent-coloured trim arc + numeric
/// percent in the centre. A tiny label sits beneath.
struct CircularDial: View {
    @Binding var value: Double
    let size: CGFloat
    let label: String
    let defaultValue: Double

    @State private var dragStartValue: Double?

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1.5)
                Circle()
                    .trim(from: 0, to: CGFloat(max(0, min(1, value))))
                    .stroke(Color.accentColor,
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int((value * 100).rounded()))")
                    .font(.system(size: max(8, size * 0.30),
                                  weight: .semibold,
                                  design: .rounded).monospacedDigit())
                    .foregroundStyle(value > 0 ? .primary : .secondary)
            }
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if dragStartValue == nil { dragStartValue = value }
                        let start = dragStartValue ?? value
                        let dy = -Double(drag.translation.height)
                        value = max(0, min(1, start + dy / 100.0))
                    }
                    .onEnded { _ in
                        dragStartValue = nil
                    }
            )
            // ⌥-click on the dial snaps to the app default. The drag
            // gesture above fires onChanged with zero translation on a
            // tap-without-move, so value stays put before this overrides.
            .simultaneousGesture(
                TapGesture()
                    .modifiers(.option)
                    .onEnded { value = defaultValue }
            )
            Text(label)
                .font(.system(size: 8, weight: .semibold).monospacedDigit())
                .foregroundStyle(.tertiary)
                .tracking(0.5)
                .fixedSize()
        }
        .help("Drag up/down to set 0–100%. ⌥-click to reset to default.")
    }
}
