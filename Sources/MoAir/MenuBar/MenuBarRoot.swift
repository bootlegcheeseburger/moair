import SwiftUI

struct MenuBarRoot: View {
    @EnvironmentObject var coord: AppCoordinator
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !coord.settings.eulaAccepted {
                EULAGateView(settings: coord.settings)
                Divider()
            } else if showSettings {
                SettingsView(settings: coord.settings)
                Divider()
            } else {
                switch coord.connectionStatus {
                case .ready:
                    VolumePanel()
                    Divider()
                    HeadTrackingPanel()
                    Divider()
                    ConnectionPanel()
                    Divider()
                case .btDisabledForTracking:
                    // Volume + Connection still work; HT section is
                    // replaced with an inline coaching block so the
                    // toggle isn't confusingly "there but broken".
                    VolumePanel()
                    Divider()
                    InlineHTGatedView(status: coord.connectionStatus)
                    Divider()
                    ConnectionPanel()
                    Divider()
                case .noDevice, .airpodsAvailableNotSelected, .airpodsOffHead, .airpodsDisconnected, .motionUnsupported, .motionDenied:
                    EmptyStateView(status: coord.connectionStatus)
                    Divider()
                }
            }
            BannerFooterRow(showSettings: $showSettings)
        }
        .padding(14)
        .frame(width: 360)
    }
}

private let appVersion: String = "v\(AppInfo.version)"

private struct BannerFooterRow: View {
    @EnvironmentObject var coord: AppCoordinator
    @Binding var showSettings: Bool

    var body: some View {
        HStack {
            Image(systemName: "headphones")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("MoAir \(appVersion)").font(.headline)
                    if FakeMode.enabled {
                        Text("DEMO")
                            .font(.caption2.bold())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.yellow.opacity(0.25), in: Capsule())
                            .foregroundStyle(Color.yellow)
                    }
                }
                if coord.audio.isSupportedHeadphone, let name = coord.audio.deviceName {
                    Text("Connected to: \(name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            // Hide Options until EULA accepted so the user can't bypass
            // the gate by switching to Settings.
            if coord.settings.eulaAccepted {
                Button(showSettings ? "Back" : "Options") {
                    showSettings.toggle()
                }
            }
            Button("Quit") {
                NSApp.terminate(nil)
            }
        }
    }
}

/// Compact replacement for HeadTrackingPanel when BT is disabled. Same
/// copy/icon as EmptyStateView but inline (panel-level) so the volume
/// + connection sections above and below stay visible.
private struct InlineHTGatedView: View {
    let status: AppCoordinator.ConnectionStatus
    @EnvironmentObject var coord: AppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: status.iconName)
                    .font(.caption)
                    .foregroundStyle(status.iconColor)
                Text(status.headline)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }
            Text(status.subhead(deviceName: coord.audio.deviceName))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct EmptyStateView: View {
    let status: AppCoordinator.ConnectionStatus
    @EnvironmentObject var coord: AppCoordinator

    var body: some View {
        VStack(alignment: .center, spacing: 8) {
            Image(systemName: status.iconName)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(status.iconColor)
                .padding(.top, 6)
            Text(status.headline)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(status.subhead(deviceName: coord.audio.deviceName))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }
}
