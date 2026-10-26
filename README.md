<p align="center">
  <img src="design/icon.png" width="128" alt="MoAir icon">
</p>

# MoAir

> Your headphones, but pro. macOS® menubar utility: head tracking → spatial-audio OSC, plus professional, dB-accurate calibration.

<p align="center">
  <img src="design/screencap.png" width="360" alt="MoAir menubar panel">
</p>

## Features

- Head tracking → OSC, with presets for common spatial-audio renderers (or custom).
- Live volume in calibrated dB.
- Connection, Codec, latency, battery, tracking stats at a glance.
- Fine tune head tracking with dead spots and sensitivity.

## Install

1. Download the latest [DMG](https://github.com/bootlegcheeseburger/moair/releases).
2. Drag MoAir into `/Applications`.
3. First launch grants Motion + Bluetooth.

Works with AirPods® (3rd gen), AirPods Pro, AirPods 4 (ANC) and AirPods Max headphones and Beats Fit Pro earbuds; macOS 14+. USB-C wired tracking needs macOS 15.4+ and the 2024 USB-C AirPods Max (firmware 7E101+).

## OSC

| Preset     | Address                   | Default port |
| ---------- | ------------------------- | ------------ |
| DAR        | `/ypr`, `/quaternion`     | 8000         |
| Apple ASAF | `/HeadPose`               | 8000         |
| Waves Nx   | `/nxosc/quaternion`       | 4242         |
| Mach1      | `/m1/orientation/*`       | 9898         |
| Virtuoso   | `/yaw`, `/pitch`, `/roll` | 8000         |
| Custom     | configurable              | configurable |

## Privacy

Local-only. No telemetry. The only network traffic is OSC to your configured host (default `127.0.0.1`).

## Hack on it

```
brew install just && just run
```

## Support

If MoAir earned its keep, you can [buy me a cheeseburger](https://www.buymeacoffee.com/bootlegcheeseburger).

## License

[MIT](LICENSE) © 2026 Bootleg Cheeseburger, LLC

Product and company names are trademarks of their respective owners; their mention does not imply affiliation or endorsement. Apple, macOS and AirPods are trademarks of Apple Inc., registered in the U.S. and other countries.
