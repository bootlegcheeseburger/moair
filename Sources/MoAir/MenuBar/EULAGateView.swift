import SwiftUI
import AppKit

/// First-launch EULA gate. Replaces normal menu content until the user
/// clicks Agree. Persisted via `AppSettings.eulaAccepted` so subsequent
/// launches go straight to the regular UI.
///
/// The EULA text is inlined as a Swift constant rather than loaded from
/// `Resources/EULA.txt` to keep the .app bundle self-contained without
/// the SwiftPM `Bundle.module` lookup (which fatalErrors on miss in some
/// build configurations — see BrandResources.swift). The .txt file is
/// kept in the source repo as the canonical, GitHub-readable copy.
/// Keep them in sync by hand on text changes.
struct EULAGateView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Before using MoAir")
                .font(.headline)
            Text("Please review and accept the terms below.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                Text(Self.eulaText)
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 220)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
            )

            HStack(spacing: 8) {
                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("Agree") {
                    settings.eulaAccepted = true
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// Same text as Resources/EULA.txt. Keep in sync when editing.
    private static let eulaText: String = """
    MoAir - End User License Agreement

    By clicking "Agree", you accept these terms.


    1. License

    MoAir is distributed under the MIT License (full text in the LICENSE
    file of the source repository). You may use, copy, modify, and
    redistribute the software subject to that license.


    2. No warranty

    The software is provided "AS IS", without warranty of any kind,
    express or implied, including but not limited to the warranties of
    merchantability, fitness for a particular purpose, and non-infringement.


    3. Limitation of liability

    To the maximum extent permitted by law, in no event shall the author
    be liable for any claim, damages, or other liability - including
    direct, indirect, incidental, special, consequential, or exemplary
    damages, lost profits, lost data, business interruption, hearing
    damage, or damage to audio equipment - arising from or in connection
    with the software or its use.


    4. Pro-audio use

    MoAir reads head-tracking data from connected headphones and sends
    OSC packets to audio applications you configure. You are responsible
    for monitoring playback levels, protecting your hearing, and avoiding
    feedback or other conditions that could damage you or your equipment.
    Do not use the software while operating a vehicle or machinery.


    5. Third-party components

    MoAir depends on open-source libraries pinned in Package.resolved.
    Each is licensed under its own terms.


    6. Privacy

    MoAir does not collect, transmit, or store personal data. It does not
    phone home, log to a remote service, or include analytics or auto-
    update. Preferences are stored locally on your machine.


    7. Termination

    This license terminates automatically if you fail to comply with
    its terms.


    If you do not agree to these terms, click "Quit" and the app will exit.
    """
}
