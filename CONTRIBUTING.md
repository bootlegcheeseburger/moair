# Contributing to MoAir

MoAir is a solo project. Contributions are welcome but please keep expectations calibrated: PRs may sit until I have time to review hardware-touching changes against real AirPods.

## Bug reports

Open an [issue](../../issues) with:
- macOS version (`sw_vers`)
- Mac model (Apple silicon / Intel)
- Headphone model + firmware version (Settings → Accessibility → AirPods)
- MoAir version (Options panel)
- What you did, what you expected, what happened
- Relevant log output: `just logs` (run before reproducing)

## Pull requests

Before opening a PR:
1. `swift build` and `swift test` pass.
2. New behavior has a clear single sentence in the PR description.
3. No new dependencies without justification.
4. No new network endpoints without explicit user opt-in.

For non-trivial changes, open an issue first to discuss scope.

## Local dev

```bash
just            # list recipes
just relaunch   # iterate on the menubar app
just fake       # synthesised motion + fake device, no hardware needed
```

Use `MOAIR_SIGN_IDENTITY=-` for ad-hoc signing if you don't have a Developer ID.

## Code style

Match what's already there. No formatter is enforced; keep functions small and comments load-bearing.
