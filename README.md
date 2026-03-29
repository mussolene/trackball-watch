# TrackBall Watch

Turn your Apple Watch into a precision input device for a cross-platform desktop host.

[![CI](https://github.com/your-org/trackball-watch/actions/workflows/ci.yml/badge.svg)](https://github.com/your-org/trackball-watch/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/your-org/trackball-watch)](https://github.com/your-org/trackball-watch/releases)

---

## How It Works

Your thumb controls the cursor, just like a trackball:

```
Hands rest on desk like when typing
          ↓
Wrist turns, thumb lands on watch face
          ↓
Watch face = trackball surface
          ↓
Swipe thumb → cursor moves
Fling → inertia (trackball mode)
Tap → click
Crown → scroll
```

**Latency:** ~7ms typical, <20ms worst case (Wi-Fi)

```
Apple Watch 7
  →[WatchConnectivity BT, ~3-5ms]→ iPhone (relay)
  →[Wi-Fi UDP, ~2-5ms]→ Desktop
```

---

## Features

| Feature | Description |
|---------|-------------|
| **Trackpad mode** | Direct cursor control with S-curve acceleration |
| **Trackball mode** | Fling with inertia physics, friction configurable |
| **Tap** | Left click |
| **Long press** | Right click |
| **Double tap** | Double click |
| **Crown** | Scroll |
| **Crown long-press** | Toggle trackpad ↔ trackball |
| **Left/Right hand** | Configurable in Settings |
| **Haptics** | Confirmation on every tap/gesture |
| **Encrypted** | AES-128-GCM with X25519 ECDH pairing |

---

## Requirements

| Component | Minimum |
|-----------|---------|
| Apple Watch | Series 7, watchOS 10+ |
| iPhone | iOS 16+ (relay) |
| macOS | 13.0+ (Ventura) |
| Windows | Windows 10 64-bit |

---

## Installation

### macOS

1. Download [`trackball-watch-macos-universal.dmg`](../../releases/latest)
2. Open DMG → drag **TrackBall Watch** to Applications
3. Launch → **grant Accessibility permission** when prompted
   *(System Settings → Privacy & Security → Accessibility)*
4. App appears in menu bar — click to open Settings

### Windows

1. Download [`trackball-watch-windows-x64.msi`](../../releases/latest)
2. Run installer → allow Windows Defender prompt (self-signed in beta, EV cert in release)
3. Allow firewall rule for UDP port **47474** when prompted
4. App starts in system tray automatically

### iPhone + Apple Watch

**Beta:** Install via TestFlight link (see [Releases](../../releases))
**Release:** Available on App Store (companion app, free)

The Watch app installs automatically alongside the iPhone app.

---

## Pairing

```
1. Desktop: system tray → "Add Device" → QR code appears
2. iPhone: open TrackBall Watch → "Pair New Desktop" → scan QR
3. Watch shows "Connected" ✓
```

Pairing uses X25519 ECDH key exchange. Session key is stored in device keychain.

---

## Usage

1. Place wrist on desk (watch facing up)
2. Press the side button on your Watch to start a session
3. Lay thumb on watch face
4. **Swipe** = move cursor
5. **Tap** = left click
6. **Long press** = right click
7. **Crown** = scroll
8. **Hold Crown** = switch mode

---

## Configuration

Open **Settings** from the system tray icon.

| Setting | Default | Description |
|---------|---------|-------------|
| Mode | Trackpad | Trackpad or Trackball |
| Hand | Right | Mirrors cursor direction for left-hand use |
| Sensitivity | 100% | Overall cursor speed |
| Curve | S-Curve | Linear / Quadratic / S-Curve (tanh) |
| Friction | 92% | Trackball mode: coasting duration |

**Built-in profiles:** Precise · Default · Fast · Linear

---

## Development

### Prerequisites

- Rust 1.75+
- Xcode 15+
- Node.js 20+

### Build Desktop Host

```bash
cd apps/host-desktop
npm install
npm run tauri dev        # development
npm run tauri build      # production
```

### Build Watch + iPhone Apps

Open `apps/watch-ios/TrackBallWatch.xcodeproj` in Xcode.
The iPhone companion and Apple Watch app live in the same Xcode project and ship as one Apple mobile bundle.

### Run Tests

```bash
cd apps/host-desktop/src-tauri
cargo test --all-features
```

### Latency Benchmark

```bash
cd tools/latency-tester
cargo run -- --host 192.168.1.5 --count 200
```

---

## Architecture

See [docs/architecture.md](docs/architecture.md) for full details.

Protocol spec: [shared/protocol/tbp_spec.md](shared/protocol/tbp_spec.md)

---

## Troubleshooting

**Cursor doesn't move (macOS)**
→ System Settings → Privacy & Security → Accessibility → enable TrackBall Watch

**"Disconnected" on watch**
→ Make sure iPhone companion is open and desktop host is running on same Wi-Fi

**Firewall blocking (Windows)**
→ Allow UDP port 47474 inbound in Windows Defender Firewall

**High latency (>30ms)**
→ Move to 5GHz Wi-Fi; check for interference; reduce Kalman R_noise

---

## Roadmap

| Phase | Target | Features |
|-------|--------|---------|
| **1.0** ✅ | macOS + Windows | Trackpad, Trackball, Apple Watch 7 |
| **2.0** | Wearable clients | Additional watch/device clients as sibling apps |
| **3.0** | Voice input | Wrist dictation, correction, command extraction |
| **4.0** | Assistant layer | Validation, proxy-assisted input, task/event capture |

---

## License

MIT © TrackBall Watch Contributors
