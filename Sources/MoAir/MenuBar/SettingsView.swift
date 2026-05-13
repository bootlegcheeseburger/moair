import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            heroHeader
                .padding(.bottom, 2)
            Divider()

            sectionLabel("OSC Destination")
            Picker("Preset", selection: $settings.preset) {
                ForEach(AppSettings.Preset.allCases) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            if settings.preset == .dar {
                Text("Sends /ypr (yaw, pitch, roll) and /quaternion (w, x, y, z) on port 8000. In DAR Preferences → Head tracking, select \"OSC head tracker\".")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if settings.preset == .asaf {
                Text("Sends /HeadPose (4-float quaternion, w, x, y, z). In the ASAF Panner plugin, set OSC Head Tracker Address to 127.0.0.1 and Port Number to match the value above. Use the Nx preset instead if you want /nxosc/quaternion.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if settings.preset == .nx {
                Text("Sends /nxosc/quaternion (Nx schema, 4 floats x, y, z, w). Point host + port at any Nx-compatible receiver (Nx Virtual Mix Room, Nx Ocean Way, etc).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            row("Host") {
                TextField(AppSettings.defaultHost, text: $settings.oscHost)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            }
            row("Port") {
                TextField(portPlaceholder, text: $settings.oscPortText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(width: 80)
                Spacer()
            }
            row("Prefix") {
                TextField(prefixPlaceholder, text: $settings.addressPrefix)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            }

            Divider().padding(.vertical, 2)

            sectionLabel("Behavior")
            Toggle("Start head-tracking on launch", isOn: $settings.streamingOnLaunch)
                .controlSize(.small)
            HStack {
                Text("dB step (Wired)")
                    .font(.caption)
                Spacer()
                Stepper(value: $settings.dbStep, in: 0.25...6, step: 0.25) {
                    Text(String(format: "%.2f dB", settings.dbStep))
                        .font(.caption.monospacedDigit())
                        .frame(minWidth: 56, alignment: .trailing)
                }
                .controlSize(.small)
            }

            Divider().padding(.vertical, 2)
            HStack {
                Spacer()
                Link(destination: URL(string: "https://www.buymeacoffee.com/bootlegcheeseburger")!) {
                    HStack(spacing: 4) {
                        Text("🍔")
                        Text("Buy me a cheeseburger")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer()
            }
            VStack(spacing: 2) {
                Text(Branding.copyright)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("Concept by Tim Nielsen")
                    .font(.caption2.italic())
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Modern collab-style banner: MoAir app icon × BLC mascot, with the
    /// title and credit anchored beneath. Mirrors the visual treatment of
    /// brand collaborations (e.g. "Brand × Collab") so the relationship
    /// between the app and the studio reads at a glance.
    private var heroHeader: some View {
        VStack(spacing: 6) {
            HStack(alignment: .center, spacing: 14) {
                appIcon
                    .frame(width: 52, height: 52)
                    .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 1)
                Text("×")
                    .font(.system(size: 22, weight: .ultraLight, design: .default))
                    .foregroundStyle(.tertiary)
                    .tracking(0)
                Link(destination: Self.studioURL) {
                    mascot
                        .frame(width: 52, height: 52)
                        .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 1)
                }
                .help("bootlegcheeseburger.com")
            }
            VStack(spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Branding.displayName)
                        .font(.title3.weight(.semibold))
                        .tracking(0.5)
                    Text("v\(AppInfo.version)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Link("by \(Branding.companyName)", destination: Self.studioURL)
                    .font(.caption2)
                    .help("bootlegcheeseburger.com")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private static let studioURL = URL(string: "https://bootlegcheeseburger.com")!

    @ViewBuilder
    private var appIcon: some View {
        if let img = BrandResources.appIcon {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private var mascot: some View {
        if let img = BrandResources.mascot {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Color.clear
        }
    }

    private func sectionLabel(_ s: String) -> some View {
        Text(s).font(.caption.bold()).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .frame(width: 50, alignment: .trailing)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private var prefixPlaceholder: String { settings.preset.prefixHint }
    private var portPlaceholder: String { String(settings.preset.defaultPort) }
}
