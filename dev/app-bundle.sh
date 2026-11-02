#!/usr/bin/env bash
# app-bundle.sh - build MoAir with SwiftPM and assemble MoAir.app: a dev bundle, or the
# release bundle `blc release` signs and packages:
#
#   MoAir.app/Contents/
#     MacOS/MoAir                         the release binary (swift build -c release)
#     Info.plist                          packaging/Info.plist with version, build and bundle id
#     Resources/MoAir.icns                the app icon
#     Resources/MoAir_MoAir.bundle        SwiftPM's resource bundle (menu icons, moai sprite)
#     Resources/blc.png                   the shop logo for the Options screen
#     Resources/contact.json              the store's contact templates (gen/contact.json)
#     Resources/THIRD-PARTY-NOTICES.txt   generated here from Package.resolved and each
#                                         package's licence file
#     Resources/Credits.rtf               the same notices, for the standard About panel
#
# The version is the one line of VERSION, set only by `blc release`; the build number is the
# commit count. Both are stamped into Info.plist, and the app reads them from there.
#
# The release bundle is unsigned: `blc release` signs it with packaging/MoAir.entitlements. A
# dev bundle is signed ad hoc with the same entitlements, so Bluetooth and Motion prompts
# attach to it. Its id is com.bootlegcheeseburger.moair.dev and it shows as "MoAir Dev", so it
# never shares permissions or the Launch Services record with a signed app. It never installs,
# launches or touches /Applications.
#
# Usage: dev/app-bundle.sh VERSION BUILD OUT
#          the release bundle, as `blc release` calls it, in OUT/MoAir.app.
#        dev/app-bundle.sh [--dry-run] [--no-build] --out DIR [--root DIR]
#          a dev bundle
#   --dry-run   print every step and command, change nothing
#   --no-build  use the existing release build in .build
#   --out DIR   where the .app goes (`blc build` picks ~/Builds/moair/dev/<describe>)
#   --root DIR  the source tree to build (default: this script's own repo)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DRY=false BUILD=true RELEASE=false OUT="" REL_VERSION="" REL_BUILD=""
case "${1:-}" in
  [0-9]*)
    [ $# -eq 3 ] || { echo "[moair] usage: dev/app-bundle.sh VERSION BUILD OUT (see --help)" >&2; exit 2; }
    RELEASE=true REL_VERSION="$1" REL_BUILD="$2" OUT="$3"
    set -- ;;
esac
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=true ;;
    --no-build) BUILD=false ;;
    --out) shift; OUT="${1:?--out needs a directory}" ;;
    --root) shift; ROOT="$(cd "${1:?--root needs a directory}" && pwd)" || exit 2 ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "[moair] unknown argument '$1' (see --help)" >&2; exit 2 ;;
  esac
  shift
done
[ -f "$ROOT/Package.swift" ] && [ -f "$ROOT/VERSION" ] \
  || { echo "[moair] $ROOT is not a MoAir tree (no Package.swift or VERSION)" >&2; exit 2; }

# The layout under ~/Builds is blc's (blc build, blc release); this script only assembles.
[ -n "$OUT" ] || { echo "dev/app-bundle.sh: --out DIR is required (blc build and blc release pass it)" >&2; exit 2; }
$DRY || mkdir -p "$OUT"

say() { echo "[moair] $*"; }
die() { echo "[moair] $*" >&2; exit 1; }
# Every change goes through run: a dry run prints it instead.
run() {
  if $DRY; then printf '  $'; printf ' %q' "$@"; printf '\n'; else "$@"; fi
}

APP_NAME="MoAir"
BUNDLE_ID="com.bootlegcheeseburger.moair.dev" DISPLAY_NAME="$APP_NAME Dev"
$RELEASE && BUNDLE_ID="com.bootlegcheeseburger.moair" DISPLAY_NAME="$APP_NAME"
APP="$OUT/$APP_NAME.app"
CONTENTS="$APP/Contents"
RES="$CONTENTS/Resources"
ENTITLEMENTS="$ROOT/packaging/$APP_NAME.entitlements"
# The version is VERSION's one line; the build number the commit count (derived, never
# stored). A release takes both from `blc release` and refuses a version that is not VERSION's.
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
[ -n "$VERSION" ] || die "VERSION is empty"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 0)"
if $RELEASE; then
  [ "$REL_VERSION" = "$VERSION" ] || die "release $REL_VERSION is not VERSION's $VERSION"
  BUILD_NUMBER="$REL_BUILD"
fi

say "$APP_NAME $VERSION-$BUILD_NUMBER, $BUNDLE_ID -> $APP"
# --disable-automatic-resolution refuses a Package.resolved that no longer matches
# Package.swift, as cargo's --locked does.
SWIFT=(swift build -c release --product "$APP_NAME" --package-path "$ROOT" --disable-automatic-resolution)
$BUILD && run "${SWIFT[@]}"
BIN="$("${SWIFT[@]}" --show-bin-path)"
[ -x "$BIN/$APP_NAME" ] || $DRY || die "no $BIN/$APP_NAME (drop --no-build)"

run rm -rf "$APP"
run mkdir -p "$CONTENTS/MacOS" "$RES"
run cp "$BIN/$APP_NAME" "$CONTENTS/MacOS/$APP_NAME"
run cp "$ROOT/packaging/Info.plist" "$CONTENTS/Info.plist"
for kv in "CFBundleIdentifier $BUNDLE_ID" "CFBundleName $DISPLAY_NAME" "CFBundleDisplayName $DISPLAY_NAME" \
    "CFBundleShortVersionString $VERSION" "CFBundleVersion $BUILD_NUMBER"; do
  run /usr/libexec/PlistBuddy -c "Set :${kv%% *} ${kv#* }" "$CONTENTS/Info.plist"
done
$DRY || plutil -lint "$CONTENTS/Info.plist" >/dev/null || die "Info.plist does not lint"
run cp "$ROOT/Resources/$APP_NAME.icns" "$RES/"
run cp -R "$BIN/${APP_NAME}_${APP_NAME}.bundle" "$RES/"
run cp "$ROOT/Sources/MoAir/Resources/blc.png" "$RES/"
run cp "$ROOT/gen/contact.json" "$RES/"

# The third-party notices, written fresh into every bundle: each package Package.resolved
# pins, with its version and the licence file at the root of its checkout. SwiftPM has no
# counterpart to cargo-about, so this lists every pin rather than walking the product's link
# graph; every package MoAir pins today is linked into it. A pin with no checkout or no
# licence file stops the bundle.
notices() {
  local resolved="$ROOT/Package.resolved" checkouts="$ROOT/.build/checkouts" n i id url ver dir lic f
  n="$(plutil -extract pins raw -o - "$resolved")"
  printf 'MoAir %s - third-party notices\n\n' "$VERSION"
  printf 'MoAir is MIT licensed (LICENSE). It links the Swift packages below.\n'
  for ((i = 0; i < n; i++)); do
    id="$(plutil -extract "pins.$i.identity" raw -o - "$resolved")"
    url="$(plutil -extract "pins.$i.location" raw -o - "$resolved")"
    ver="$(plutil -extract "pins.$i.state.version" raw -o - "$resolved" 2>/dev/null \
      || plutil -extract "pins.$i.state.revision" raw -o - "$resolved")"
    dir="$checkouts/$(basename "${url%.git}")"
    lic=""
    for f in LICENSE LICENSE.md LICENSE.txt LICENCE COPYING NOTICE; do
      [ -f "$dir/$f" ] && { lic="$dir/$f"; break; }
    done
    [ -n "$lic" ] || die "Swift package $id has no licence file in $dir"
    printf '\n%s\n%s %s\n%s\n\n' "------------------------------------------------------------" "$id" "$ver" "$url"
    cat "$lic"
  done
}
if $DRY; then
  echo "  (notices from Package.resolved -> $RES/THIRD-PARTY-NOTICES.txt)"
else
  notices > "$RES/THIRD-PARTY-NOTICES.txt"
fi
run textutil -convert rtf -font Menlo-Regular -fontsize 10 \
  -output "$RES/Credits.rtf" "$RES/THIRD-PARTY-NOTICES.txt"

$RELEASE || run codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP"
say "bundled $APP"
