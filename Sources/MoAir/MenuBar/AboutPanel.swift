import AppKit

/// The standard macOS About panel. Its credits pane shows the contact lines
/// (from the bundled contact.json, as mailto links) above the third-party
/// notices in `Contents/Resources/Credits.rtf` (dev/app-bundle.sh writes it).
enum AboutPanel {
    static func show() {
        // MoAir is an accessory app: activate so the panel comes to the front.
        NSApp.activate()
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        // Without contact lines, leave .credits unset: the panel reads Credits.rtf itself.
        if let credits = credits() {
            options[.credits] = credits
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    /// Contact links, then Credits.rtf. Nil when there is no contact line to add.
    private static func credits() -> NSAttributedString? {
        guard let contact = ContactTemplates.bundled else { return nil }
        let fields = ContactTemplates.appFields
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        let plain: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: centered,
        ]

        let out = NSMutableAttributedString()
        for kind in contact.kinds {
            guard case let .success(mailto) = contact.mailto(kind.kind, fields: fields),
                  let url = URL(string: mailto) else { continue }
            var link = plain
            link[.link] = url
            out.append(NSAttributedString(string: displayLabel(kind.label), attributes: link))
            out.append(NSAttributedString(string: ": \(kind.to)\n", attributes: plain))
        }
        guard out.length > 0 else { return nil }

        if let url = Bundle.main.url(forResource: "Credits", withExtension: "rtf"),
           let notices = try? NSAttributedString(
               url: url,
               options: [.documentType: NSAttributedString.DocumentType.rtf],
               documentAttributes: nil
           )
        {
            out.append(NSAttributedString(string: "\n", attributes: plain))
            out.append(notices)
        }
        return out
    }

    /// A menu label without its trailing ellipsis ("Report a Bug..." reads
    /// "Report a Bug" as a link).
    private static func displayLabel(_ label: String) -> String {
        var s = label
        for suffix in ["...", "\u{2026}"] where s.hasSuffix(suffix) {
            s.removeLast(suffix.count)
        }
        return s
    }
}
