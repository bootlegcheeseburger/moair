# MoAir

MoAir is a menu bar app that reads head orientation from AirPods and Beats Fit Pro and sends
it as OSC to spatial audio tools (`README.md`). It is free, MIT licensed and developed in the
open: this repository is public, so nothing in it names a private shop repository or path.

## The package

- One SwiftPM executable target, `Sources/MoAir`, with OSCKit as its one direct dependency.
  `Package.resolved` is committed.
- Check: `swift build` (blc.toml `[check]`). There is no test target yet.
- `MOAIR_FAKE=1 swift run` runs the bare binary with a fake device and synthesised motion, no
  hardware needed. A bare binary has no bundle, so it shows version `0.0.0-dev`.
- Logs: `log stream --style compact --process MoAir`. Permission prompts are reset with
  `tccutil reset Motion <bundle id>` and `tccutil reset Bluetooth <bundle id>`.

## Versions

The version is the one line of `VERSION`, set only by `blc release`; the build number is the
commit count. `dev/app-bundle.sh` stamps both into the bundle's `Info.plist`, and the app reads
its version from there (`AppInfo.version`), never from a copy in source.

## Builds and releases

`blc build` makes a dev bundle, "MoAir Dev" with id `com.bootlegcheeseburger.moair.dev`, signed
ad hoc, through `dev/app-bundle.sh`; `blc run` builds and launches it. `blc release` cuts a
release and calls the same bundler for the unsigned release bundle, which it signs with
`packaging/MoAir.entitlements` and packages. MoAir has no Sparkle and no feed; releases are
published on this repository's GitHub releases by a person.

The bundler writes `THIRD-PARTY-NOTICES.txt` from `Package.resolved` and each package's licence
file in `.build/checkouts`, and `Credits.rtf` from it for the About panel. SwiftPM has no
counterpart to cargo-about or cargo-deny: the bundler lists every pin and stops on a missing
licence file, and a new dependency's licence is checked by hand before it lands.

## Resources

- `gen/contact.json` is a copy of the store catalog's generated contact templates for moair;
  copy it again when the catalog's contact kinds change.
- The moai sprite sheet and menu icons were drawn by the shop (user, 2026-10-26), as is
  `blc.png`, the shop logo. The bundle has no third-party art or fonts.
- The icons are made from the TIFFs in `design/` with `sips`, `iconutil` and ImageMagick; the
  commands are the old Justfile's `tool-icon` recipe (`git show 51917f3:Justfile`).
