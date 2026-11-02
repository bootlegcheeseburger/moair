# Contributing to MoAir

MoAir is a solo project. Contributions are welcome but please keep expectations calibrated: PRs may sit until I have time to review hardware-touching changes against real AirPods.

## Bug reports

Open an [issue](https://github.com/bootlegcheeseburger/moair/issues) with:
- macOS version (`sw_vers`)
- Mac model (Apple silicon / Intel)
- Headphone model + firmware version (Settings → Accessibility → AirPods)
- MoAir version (Options panel)
- What you did, what you expected, what happened
- Relevant log output: `log stream --style compact --process MoAir` (run before reproducing)

## Pull requests

Before opening a PR:
1. `swift build` passes.
2. New behavior has a clear single sentence in the PR description.
3. No new dependencies without justification.
4. No new network endpoints without explicit user opt-in.

For non-trivial changes, open an issue first to discuss scope.

## Local dev

```bash
swift build                 # compile
MOAIR_FAKE=1 swift run      # synthesised motion + fake device, no hardware needed
dev/app-bundle.sh --out DIR # an ad-hoc signed "MoAir Dev.app" (bundle id <id>.dev) in DIR
```

The app bundle carries the menu bar resources and asks for Bluetooth and Motion access, so run `DIR/MoAir Dev.app` to try anything hardware-facing. Release builds are signed and notarized by the maintainer.

## Code style

Match what's already there. No formatter is enforced; keep functions small and comments load-bearing.
