import SwiftUI
import AppKit

@main
struct MoAirApp: App {
    @StateObject private var coord = AppCoordinator()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarRoot()
                .environmentObject(coord)
        } label: {
            MenuBarLabel(coord: coord)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var coord: AppCoordinator
    @State private var displayedText: String = ""
    @State private var animationTask: Task<Void, Never>?

    /// Per-character step delay for the build-in/build-out animation.
    /// 35 ms × ~5 chars ≈ 175 ms total — fast enough not to feel laggy
    /// but slow enough that the icon's positional shift reads as motion
    /// rather than a snap. Macos rasterises the menubar at a relatively
    /// slow cadence, so faster than ~25 ms doesn't actually render.
    private static let stepDelayNanos: UInt64 = 35_000_000

    var body: some View {
        HStack(spacing: 4) {
            if !displayedText.isEmpty {
                Text(displayedText)
            }
            iconView
        }
        .onAppear { displayedText = titleText }
        .onChange(of: titleText) { _, newTarget in
            animateOrSnap(to: newTarget)
        }
    }

    @ViewBuilder
    private var iconView: some View {
        if coord.isFlashingRecalibration {
            // Swap to a reticle during the ⌥-click recal flash — the
            // quickRecalibrate task toggles the flag ON/OFF/ON/OFF to
            // produce the double-blink confirmation.
            Image(systemName: "scope")
        } else {
            Image(nsImage: menuImage)
        }
    }

    /// Drive the build-in / build-out one character at a time when the
    /// label is appearing or disappearing. For value-only changes (e.g.
    /// dB ticking from −12 to −11 while headphones are still on) we snap
    /// directly, since stepping there would look like a glitch.
    private func animateOrSnap(to target: String) {
        animationTask?.cancel()
        let wasEmpty = displayedText.isEmpty
        let willBeEmpty = target.isEmpty
        guard wasEmpty != willBeEmpty else {
            displayedText = target
            return
        }
        animationTask = Task { @MainActor in
            await stepDisplayedText(to: target)
        }
    }

    @MainActor
    private func stepDisplayedText(to target: String) async {
        // Walk one character at a time toward the target: shrink while
        // the current displayed text isn't a prefix of target, otherwise
        // grow. Handles "" ↔ "−12dB" cleanly and copes with target
        // changing mid-animation (cancellation + restart).
        while !Task.isCancelled && displayedText != target {
            if target.hasPrefix(displayedText) {
                let nextLen = displayedText.count + 1
                displayedText = String(target.prefix(nextLen))
            } else {
                displayedText = String(displayedText.dropLast())
            }
            try? await Task.sleep(nanoseconds: Self.stepDelayNanos)
        }
    }

    /// Which of the three custom menubar glyphs to show. Loaded via
    /// `Bundle.image(forResource:)` so the matching @1x/@2x pair is
    /// auto-paired into a single multi-rep NSImage with the correct
    /// point size — `NSImage(contentsOf:)` would only load one rep and
    /// mistake pixel count for point count, causing fuzzy upscale on
    /// retina menubars.
    private var menuImage: NSImage {
        // Use the live moai sprite only while motion samples are still
        // arriving. `hasFreshSamples` flips false within ~0.5 s of the
        // stream going silent (cans pulled off head) — without that
        // gate, CoreMotion's didDisconnect lag leaves the sprite frozen
        // at the last orientation for several seconds.
        if coord.headTracker.state == .streaming && coord.headTracker.hasFreshSamples {
            let s = coord.headTracker.displayedStable
            return MoaiSprite.image(yawDeg: s.yawDegrees, pitchDeg: s.pitchDegrees)
        }
        return staticMenuImage
    }

    /// Three-state static glyph: connected+ready, connected-but-BT-off
    /// (still want the "connected" icon since headphones are there), or
    /// disconnected/off. Loaded via MenubarResources so a missing
    /// bundle yields an empty image instead of a `Bundle.module`
    /// fatalError on launch (which crashed v0.8.0 on fresh installs).
    private var staticMenuImage: NSImage {
        let name: String
        switch coord.connectionStatus {
        case .ready, .btDisabledForTracking:
            name = "moair-menu"
        case .airpodsOffHead, .airpodsDisconnected, .noDevice,
             .airpodsAvailableNotSelected, .motionUnsupported, .motionDenied:
            name = "moair-menu-off"
        }
        let img = MenubarResources.image(named: name) ?? NSImage()
        img.isTemplate = true
        return img
    }

    private var titleText: String {
        guard coord.connectionStatus.canControlVolume else { return "" }
        // dB mode only when the device's dB axis is actually trustworthy
        // (hybrid: BT-labeled transport with audio routing over USB-C).
        // BT-only and USB-only fall back to a percent readout — the
        // device's dB readback in those modes doesn't track audible
        // attenuation faithfully.
        if coord.audio.setupQuality == .hybrid,
           let db = coord.audio.derivedVolumeDb ?? coord.audio.volumeDecibels {
            let rounded = Int(db.rounded())
            if rounded <= -100 { return "−∞" }
            return "\(rounded)dB"
        }
        let percent = Int((coord.audio.volumeScalar * 100).rounded())
        return "\(percent)%"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
