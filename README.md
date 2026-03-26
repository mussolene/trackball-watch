# TrackBall Watch

Turn your Apple Watch into a precision trackball/trackpad. No additional hardware required.

## How It Works

```
Apple Watch 7
  → [WatchConnectivity BT, ~3-5ms] → iPhone (background companion)
  → [Wi-Fi UDP, ~2-5ms] → Desktop Host
  Total latency: ~5-15ms
```

Your thumb controls the cursor like a trackball — the watch face becomes the trackball surface.

## Features

- **Trackpad mode**: Direct cursor control with acceleration curve
- **Trackball mode**: Fling with inertia physics
- **Digital Crown**: Scroll
- **Tap**: Left click
- **Long press**: Right click
- **Crown long-press**: Switch mode
- **Left/right hand**: Configurable

## Requirements

| Component | Requirement |
|-----------|-------------|
| Apple Watch | Series 7+ (watchOS 10+) |
| iPhone | iOS 16+ (relay) |
| Mac | macOS 13+ (Accessibility permission) |
| Windows | Windows 10+ (no admin required) |

## Installation

### macOS
1. Download `trackball-watch-macos-universal.dmg` from [Releases](../../releases)
2. Open DMG → drag to Applications
3. Launch → grant Accessibility permission when prompted
4. Scan QR code with iPhone app

### Windows
1. Download `trackball-watch-windows-x64.msi` from [Releases](../../releases)
2. Run installer (allow firewall rule for UDP 47474)
3. App starts in system tray automatically
4. Scan QR code with iPhone app

### iPhone + Apple Watch
Install via TestFlight (beta) or App Store (release).
The Watch app installs automatically alongside the iPhone app.

## Pairing

1. Launch Desktop Host → System Tray → **"Add Device"**
2. QR code appears with IP + session token
3. On iPhone: open TrackBall Watch → **"Pair New Desktop"**
4. Scan QR → automatic ECDH handshake
5. Watch shows **"Connected"** ✓

## Architecture

See [docs/architecture.md](docs/architecture.md) for full details.

Protocol spec: [shared/protocol/tbp_spec.md](shared/protocol/tbp_spec.md)

## Development

### Prerequisites
- Rust 1.75+
- Xcode 15+
- Node.js 20+ (for Tauri UI)

### Build Desktop Host
```bash
cd apps/host-desktop
npm install
npm run tauri dev
```

### Build Watch + iOS
Open `apps/watch-ios/TrackBallWatch.xcodeproj` in Xcode.

## License

MIT
