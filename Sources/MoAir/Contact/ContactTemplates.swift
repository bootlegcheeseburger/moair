import AppKit
import Foundation

/// Pre-drafted contact emails as `mailto:` URLs, from the store catalog's
/// contact templates (`gen/contact.json`, a copy of the store's generated file,
/// bundled by dev/app-bundle.sh as `Contents/Resources/contact.json`).
///
/// Mirrors the shop's shared contact-template rules:
/// - `{app}` `{version}` `{build}` `{macos}` `{serial_last4}` are filled in
///   one pass; any placeholder without a value becomes a blank, never a
///   literal `{x}`. MoAir has no serial, so `{serial_last4}` is always blank.
/// - With no version, the subject tag `[{app} {version}]` reads `[{app}]`.
/// - Subject line breaks become spaces; body line breaks become CRLF.
/// - Subject and body are percent-encoded per RFC 6068: every UTF-8 byte
///   outside RFC 3986's unreserved set, so a line break is `%0D%0A`.
/// - A mailto over `mailtoMax` characters is an error, never truncated.
struct ContactTemplates: Decodable {
    struct Kind: Decodable, Identifiable {
        let kind: String
        let label: String
        let to: String
        let subject: String
        let body: String

        var id: String {
            kind
        }
    }

    /// The values the placeholders are filled with. An empty field fills as a blank.
    struct Fields: Equatable {
        var app: String
        var version: String
        var build: String
        var macos: String
        var serialLast4: String?
    }

    enum Failure: Error, Equatable {
        case unknownKind(String)
        case tooLong(kind: String, length: Int)
    }

    /// The longest mailto any mail client is trusted with (store's `mailto_max`).
    static let mailtoMax = 1800

    /// How many trailing serial characters a mailto may carry.
    static let serialLast4Length = 4

    let app: String
    /// Catalog (display) order.
    let kinds: [Kind]

    /// The bundled templates, or nil when the bundle has no readable contact.json
    /// (a bare `swift build` binary has no app wrapper to carry it).
    static let bundled: ContactTemplates? = {
        guard let url = Bundle.main.url(forResource: "contact", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ContactTemplates.self, from: data)
    }()

    /// The running app's fields: display name, version, build, macOS version.
    static var appFields: Fields {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return Fields(app: Branding.displayName, version: AppInfo.version,
                      build: build, macos: macosVersion(), serialLast4: nil)
    }

    /// The running macOS version, like `15.3.1` or `15.0`.
    static func macosVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion == 0
            ? "\(v.majorVersion).\(v.minorVersion)"
            : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// The filled, encoded `mailto:` for `kind`.
    func mailto(_ kind: String, fields: Fields) -> Result<String, Failure> {
        guard let t = kinds.first(where: { $0.kind == kind }) else {
            return .failure(.unknownKind(kind))
        }
        var fields = fields
        fields.serialLast4 = fields.serialLast4.map {
            String(String.UnicodeScalarView($0.unicodeScalars.suffix(Self.serialLast4Length)))
        }
        let subject = Self.oneLine(Self.fill(Self.subjectTag(t.subject, version: fields.version), fields))
        let body = Self.crlf(Self.fill(t.body, fields))
        let url = "mailto:\(t.to)?subject=\(Self.encode(subject))&body=\(Self.encode(body))"
        let length = url.unicodeScalars.count
        if length > Self.mailtoMax {
            return .failure(.tooLong(kind: kind, length: length))
        }
        return .success(url)
    }

    /// Opens `kind`'s mailto in the user's mail app. Logs and does nothing on failure.
    @discardableResult
    func open(_ kind: String) -> Bool {
        switch mailto(kind, fields: Self.appFields) {
        case let .success(s):
            guard let url = URL(string: s) else { return false }
            return NSWorkspace.shared.open(url)
        case let .failure(e):
            NSLog("MoAir contact: \(e)")
            return false
        }
    }

    /// With no version, the tag `[{app} {version}]` reads `[{app}]`.
    static func subjectTag(_ subject: String, version: String) -> String {
        guard version.isEmpty, let r = subject.range(of: " {version}]") else { return subject }
        return subject.replacingCharacters(in: r, with: "]")
    }

    /// One pass over `{name}` spans (no braces inside): known names take their
    /// field, any other becomes a blank. Filled values are not scanned again.
    /// Works on Unicode scalars, so a brace is never hidden inside a grapheme.
    static func fill(_ text: String, _ fields: Fields) -> String {
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            guard scalars[i] == "{" else {
                out.append(scalars[i])
                i += 1
                continue
            }
            var j = i + 1
            while j < scalars.count, scalars[j] != "{", scalars[j] != "}" {
                j += 1
            }
            if j < scalars.count, scalars[j] == "}" {
                var name = String.UnicodeScalarView()
                name.append(contentsOf: scalars[(i + 1) ..< j])
                out.append(contentsOf: value(String(name), fields).unicodeScalars)
                i = j + 1
            } else {
                out.append("{")
                i += 1
            }
        }
        return String(out)
    }

    /// Every CR and LF becomes a space.
    static func oneLine(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for c in s.unicodeScalars {
            out.append(c == "\r" || c == "\n" ? " " : c)
        }
        return String(out)
    }

    /// Every line break (CRLF, lone CR, lone LF) becomes CRLF.
    static func crlf(_ s: String) -> String {
        let scalars = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if c == "\r" || c == "\n" {
                out.append(contentsOf: "\r\n".unicodeScalars)
                if c == "\r", i + 1 < scalars.count, scalars[i + 1] == "\n" {
                    i += 1
                }
            } else {
                out.append(c)
            }
            i += 1
        }
        return String(out)
    }

    private static func value(_ name: String, _ f: Fields) -> String {
        switch name {
        case "app": return f.app
        case "version": return f.version
        case "build": return f.build
        case "macos": return f.macos
        case "serial_last4": return f.serialLast4 ?? ""
        default: return ""
        }
    }

    /// Percent-encodes every UTF-8 byte outside RFC 3986's unreserved set
    /// (the longest form; a space is `%20`), as the store's length check does.
    static func encode(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count * 3)
        for b in s.utf8 {
            switch b {
            case UInt8(ascii: "A") ... UInt8(ascii: "Z"), UInt8(ascii: "a") ... UInt8(ascii: "z"),
                 UInt8(ascii: "0") ... UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
                out.unicodeScalars.append(Unicode.Scalar(b))
            default:
                out += String(format: "%%%02X", b)
            }
        }
        return out
    }
}
