# Security Policy

## Supported versions

Only the latest released version of MoAir receives security fixes.

## Reporting a vulnerability

Please do not open a public GitHub issue for security problems.

Use GitHub's private advisory channel:
[Report a vulnerability](../../security/advisories/new)

Or email: dan@dantimmons.net

I aim to acknowledge reports within 72 hours. As a solo maintainer, fix
turnaround depends on severity and availability; expect days to weeks
rather than hours.

## Scope

In scope:
- The MoAir macOS app and its build/release scripts in this repo.
- The notarized DMG distributed via GitHub Releases.

Out of scope:
- Third-party dependencies (report upstream; I'll bump after their fix).
- Issues requiring physical access to an unlocked machine.
- macOS / AirPods firmware bugs.

## What MoAir touches

- Reads CoreMotion data from connected AirPods / Beats Fit Pro.
- Reads CoreAudio device state and Bluetooth advertisements (battery / RSSI).
- Sends UDP OSC packets to a user-configured host:port (default `127.0.0.1:7000`).
- Stores preferences in `UserDefaults` only. No network telemetry, no analytics,
  no remote auto-update, no account system.

The app is sandbox-disabled (uses CoreAudio HAL APIs that aren't sandbox-safe)
but ships with Hardened Runtime + Developer ID signature + notarization.
