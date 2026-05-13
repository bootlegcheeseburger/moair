import Foundation
import AppKit

/// User-visible branding strings. Internal identifiers (target name, type
/// names, file-system paths) intentionally stay as `MoAir`; this enum is
/// for chrome only.
enum Branding {
    static let displayName = "MoAir"
    static let companyName = "Bootleg Cheeseburger"
    static let copyright   = "© 2026 Bootleg Cheeseburger, LLC"
}

enum AppInfo {
    /// User-facing version. Bundle.main.infoDictionary has the plist value
    /// only when MoAir runs from the .app wrapper — `swift run`, `swift
    /// build` debug binaries, and most other SwiftPM-launch paths give us
    /// no `CFBundleShortVersionString`. The hardcoded fallback below is
    /// kept in lockstep with `Resources/Info.plist` by the Justfile's
    /// `bump-major` / `bump-minor` recipes, so the Options screen never
    /// displays "0.0.0" regardless of how MoAir was launched.
    static let version: String = {
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           !v.isEmpty {
            return v
        }
        return hardcodedVersion
    }()

    /// Bumped automatically by `just bump {major|minor|patch}`. Don't edit
    /// by hand — keep equal to `CFBundleShortVersionString` in `Resources/Info.plist`.
    static let hardcodedVersion = "0.8.0"
}

/// Safe loader for the branded icons used by the Options screen.
///
/// We deliberately avoid the SwiftPM-generated `Bundle.module` accessor:
/// when the assembled `MoAir.app` doesn't ship the `MoAir_MoAir.bundle`
/// directory (as happened with earlier `bundle:` recipes), the auto-
/// generated `Bundle.module` calls `fatalError("could not load resource
/// bundle…")`, which manifests on production machines as a log-less crash
/// the moment the user opens Options. This loader returns `nil` instead,
/// so a missing resource just renders a placeholder.
///
/// Lookup order:
///   1. `Bundle.main.url(forResource:withExtension:)` — production .app
///      (`Contents/Resources/`).
///   2. The SwiftPM resource bundle next to the running binary — dev /
///      `swift run` flows.
///   3. For the app icon only, `NSApp.applicationIconImage` — last-ditch
///      fallback so the banner still has *some* icon if both bundle
///      lookups fail.
enum BrandResources {
    static let appIcon: NSImage? = {
        if let img = loadImage(name: "MoAir", ext: "icns") { return img }
        return NSApplication.shared.applicationIconImage
    }()

    static let mascot: NSImage? = loadImage(name: "blc", ext: "png")

    private static func loadImage(name: String, ext: String) -> NSImage? {
        if let url = Bundle.main.url(forResource: name, withExtension: ext),
           let img = NSImage(contentsOf: url) {
            return img
        }
        if let bundle = swiftPMBundle,
           let url = bundle.url(forResource: name, withExtension: ext),
           let img = NSImage(contentsOf: url) {
            return img
        }
        return nil
    }

    /// Manual lookup of the SwiftPM-generated resource bundle without
    /// going through `Bundle.module` (which fatalErrors on miss).
    private static let swiftPMBundle: Bundle? = {
        let bundleName = "MoAir_MoAir.bundle"
        let candidates: [URL] = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources").appendingPathComponent(bundleName),
            Bundle.main.bundleURL.appendingPathComponent(bundleName),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(bundleName),
        ].compactMap { $0 }
        for url in candidates {
            if let b = Bundle(url: url) { return b }
        }
        return nil
    }()
}
