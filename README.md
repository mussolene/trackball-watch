# TrackBall Watch

TrackBall Watch is a wearable-first, cross-device input platform in active development.

The product starts with Apple Watch as a precision pointing device for a desktop host, but the target product is broader:

- wearable cursor control with trackball-style mechanics
- multi-host switching
- keyboard + pointer workflows around a phone or watch hub
- shared clipboard / input buffer across connected hosts
- short voice input and assistant-assisted correction
- fast capture of tasks, reminders, and events

Today the repository contains the first production line of that platform:

- desktop host for macOS / Windows
- Apple mobile bundle
  - iPhone companion / relay
  - Apple Watch client

This is not yet the final product shape. The current codebase is the first implementation of the input layer that the broader product will build on.

---

## Product Vision

The long-term goal is to make wearable devices useful as real input tools, not just remote-control accessories.

TrackBall Watch is being built as a global input product for people who move between machines, work from the keyboard, and need a fast secondary control channel that is always on the body.

The intended product stack is:

1. low-latency wearable pointer input
2. keyboard and clipboard workflows across hosts
3. voice input and command capture from the wrist
4. assistant-assisted validation, correction, and action routing
5. capture of reminders, tasks, and events from quick natural input

The core engineering rule is that real-time input stays deterministic. Assistant behavior is layered on top where ambiguity exists, but never placed in the hot path of pointer motion.

## Current Focus

The repository is currently focused on the first hard part:

- precise cursor control
- stable trackball-style mechanics
- low-latency relay from watch to desktop
- clicks, scroll, host switching, and core pointer interactions

This stage matters because the rest of the product only makes sense if the input layer is fast, predictable, and good enough for real work.

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

## Current Features

| Feature | Description |
|---------|-------------|
| **Trackpad mode** | Surface-driven virtual-ball cursor control |
| **Trackball mode** | Virtual trackball with fling inertia |
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

1. Download [`trackball-watch-macos-universal.dmg`](https://github.com/mussolene/trackball-watch/releases/latest)
2. Open DMG → drag **TrackBall Watch** to Applications
3. Launch → **grant Accessibility permission** when prompted
   *(System Settings → Privacy & Security → Accessibility)*
4. App appears in menu bar — click to open Settings

### Windows

1. Download [`trackball-watch-windows-x64.msi`](https://github.com/mussolene/trackball-watch/releases/latest)
2. Run installer → allow the standard Windows security prompt if shown
3. Allow firewall rule for UDP port **47474** when prompted
4. App starts in system tray automatically

### iPhone + Apple Watch

**Beta:** distribute through TestFlight or direct development install
**Release:** App Store distribution once the Apple bundle is production-ready

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
| Mode | Trackball | Trackpad or Trackball |
| Sensitivity | 100% | Overall cursor speed |
| Curve | S-Curve | Linear / Quadratic / S-Curve (tanh) |
| Friction | 85% | Trackball mode: coasting duration |

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
cargo run -- --host <desktop-host> --count 200
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

## Product Direction

The repository is moving toward a multi-client input platform rather than a single Apple Watch accessory app.

Planned product directions:

- additional wearable clients as sibling apps
- richer multi-host workflows
- external keyboard integration through a mobile hub
- shared clipboard / shared input buffer across devices
- quick command and dictation flows from wearable clients
- assistant-assisted text normalization and action routing

The intended differentiator is not "another remote mouse app". The intended differentiator is a better input model and a unified workflow across wearable, phone, keyboard, and desktop.

## Roadmap

| Phase | Target | Features |
|-------|--------|---------|
| **1.0** ✅ | macOS + Windows | Trackpad, Trackball, Apple Watch 7 |
| **2.0** | Wearable clients | Additional watch/device clients as sibling apps |
| **3.0** | Voice input | Wrist dictation, correction, command extraction |
| **4.0** | Assistant layer | Validation, proxy-assisted input, task/event capture |

---

## License

All rights reserved © TrackBall Watch Contributors
