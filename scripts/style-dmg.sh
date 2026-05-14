#!/usr/bin/env bash
# Style a writable DMG (UDRW format) with a roomy window, 256pt icons, and
# a side-by-side "drag-to-Applications" layout. Called by `just build-
# release` between the `hdiutil create` and the `hdiutil convert` to UDZO.
#
# Usage:
#   scripts/style-dmg.sh <volume-name> <app-name> <rw-dmg-path>
#
# Requirements: macOS with a GUI login session — the styling is done by
# scripting Finder via AppleScript, which won't work on a headless box.

set -euo pipefail

volname="$1"
app_name="$2"
rw_dmg="$3"

# Mount the writable DMG and capture the partition's device node so we
# can guarantee a clean detach. `hdiutil attach` prints several lines;
# the first /dev/diskN entry is the volume we just mounted.
device=$(hdiutil attach -readwrite -noverify -noautoopen "$rw_dmg" \
  | awk '/^\/dev\// { print $1; exit }')

# Always detach, even if AppleScript bombs out -- otherwise the next
# `just release` would fail trying to attach an already-mounted
# image, and the user would have to eject by hand.
cleanup() {
    hdiutil detach "$device" -quiet -force >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Give Finder a moment to register the new volume before we start
# bossing it around. Two seconds has been reliable across macOS 14/15.
sleep 2

# Window {200, 200, 1040, 700} = 840pt wide × 500pt tall — roomy enough
# that 256pt icons + their labels never trigger Finder scrollbars.
# Two icons centred in their respective halves: left at x=210
# (centre of 0..420), right at x=630 (centre of 420..840), both at y=240
# so the icon + label sits comfortably below the title bar.
# Toolbar / sidebar / statusbar all hidden so the window reads as a
# "drop here" landing zone, not a Finder browser.
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "${volname}"
        open
        delay 1
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set sidebar width of container window to 0
        set the bounds of container window to {200, 200, 1040, 700}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 256
        set text size of viewOptions to 14
        set position of item "${app_name}.app" of container window to {210, 240}
        set position of item "Applications" of container window to {630, 240}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

# Force pending writes to disk before detaching so the .DS_Store with
# our view options is actually persisted in the image.
sync
hdiutil detach "$device" -quiet
trap - EXIT
