import AppKit

/// Crash-safe replacement for `Bundle.module.image(forResource:)` for
/// menubar/sprite assets that live inside the SwiftPM-generated
/// `MoAir_MoAir.bundle`.
///
/// `Bundle.module` calls `fatalError("unable to find bundle named …")`
/// when its lookup fails — and on macOS it CAN fail at runtime because
/// SwiftPM emits the resource bundle as a flat directory (no
/// `Contents/Info.plist`), which `Bundle.init(url:)` refuses to
/// recognise on a clean install. The crash manifests during the very
/// first menubar render: app launches, immediately dies, no log.
///
/// This loader tries the bundle path first (works in dev where the
/// bundle was placed somewhere SwiftPM's accessor would have found) and
/// falls back to direct file URLs into the @1x and @2x pair, packed
/// into a single multi-rep NSImage so retina pairing still works.
enum MenubarResources {
    static func image(named name: String) -> NSImage? {
        if let bundle = swiftPMBundle, let img = bundle.image(forResource: name) {
            return img
        }
        // Direct-URL fallback. Loads @1x + @2x as separate reps and
        // labels the @2x rep so AppKit picks the right one for the
        // current display scale.
        let bundleResources = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/MoAir_MoAir.bundle")
        let url1x = bundleResources.appendingPathComponent("\(name).png")
        let url2x = bundleResources.appendingPathComponent("\(name)@2x.png")
        let img = NSImage()
        var added = false
        if let rep = NSImageRep(contentsOf: url1x) {
            img.addRepresentation(rep)
            added = true
        }
        if let rep = NSImageRep(contentsOf: url2x) {
            // Mark as 2x by halving its declared point size.
            rep.size = NSSize(width: rep.pixelsWide / 2, height: rep.pixelsHigh / 2)
            img.addRepresentation(rep)
            added = true
        }
        return added ? img : nil
    }

    /// Locate the SwiftPM resource bundle without invoking
    /// `Bundle.module` (which fatalErrors on miss). Returns nil if
    /// `Bundle.init(url:)` refuses the directory — flat bundles often
    /// fail this check on macOS.
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
