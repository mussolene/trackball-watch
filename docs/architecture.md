# TrackBall Watch — Architecture

## System Overview

```
Apple Watch 7
  │
  │  WatchConnectivity (Bluetooth, ~3-5ms)
  │  sendMessage() / transferUserInfo() fallback
  ▼
iPhone (background companion)
  │
  │  Network.framework UDP (~2-5ms over Wi-Fi)
  │  NWConnection to desktop host
  ▼
Desktop Host (macOS / Windows)
  │
  ├─ UDP Server (tokio, port 47474)
  ├─ TBP Protocol decoder (bincode)
  ├─ 2D Kalman filter
  ├─ Acceleration curve (S-curve/tanh)
  ├─ Input injector (CGEvent / SendInput)
  └─ Tauri UI (system tray + settings)

Total latency target: p50 < 15ms, p99 < 30ms
```

## Component Details

### 1. Apple Watch App (`apps/watch-ios/`)

**Language:** Swift/SwiftUI, watchOS 10+

| File | Responsibility |
|------|---------------|
| `InputCaptureView.swift` | `SpatialEventGesture` full-screen touch capture |
| `GestureRecognizer.swift` | On-watch gesture classifier (tap/fling/swipe) |
| `WatchSessionManager.swift` | `WCSession.sendMessage()` dispatch |
| `CrownHandler.swift` | Digital Crown → CROWN packets |
| `ExtendedRuntimeManager.swift` | `WKExtendedRuntimeSession(.workout)` |
| `TBPPacket.swift` | Packet serializer (little-endian) |

**Touch normalization:** Raw `CGPoint` → -32767..32767 per axis.

**Why on-device gesture recognition?** To minimize WatchConnectivity traffic. Instead of sending every TOUCH_MOVED at 60Hz, a single GESTURE packet is sent for tap/fling. Only trackpad mode sends raw TOUCH events.

### 2. iPhone Companion (`apps/companion-ios/`)

**Language:** Swift, iOS 16+

| File | Responsibility |
|------|---------------|
| `WatchRelayService.swift` | WCSession → UDP bridge |
| `UDPRelay.swift` | NWConnection UDP client |
| `PairingService.swift` | QR parse → DesktopConfig storage |
| `AppDelegate.swift` | PushKit VoIP for background wakeup |

**Background execution strategy:**
1. `UIApplication.beginBackgroundTask` — up to 30s in background
2. PushKit VoIP registration — wakes app for incoming push
3. App stays alive as long as watch session is active

### 3. Desktop Host (`apps/host-desktop/`)

**Language:** Rust + Tauri v2 (UI: Svelte)

```
UDP :47474
  └─ UdpServer (tokio)
       └─ handle_input_event()
            ├─ Touch → Kalman2D → apply_curve_2d() → InputInjector::move_relative()
            ├─ Gesture(TAP) → InputInjector::left_click()
            ├─ Gesture(FLING) → TrackballState::fling() [trackball mode]
            ├─ Crown → InputInjector::scroll_vertical()
            └─ Heartbeat → session keepalive
```

**Input pipeline latency breakdown:**
- UDP recv: ~0.1ms
- Bincode decode: ~0.01ms
- Kalman filter: ~0.05ms
- Injector (CGEvent): ~1ms
- **Total processing: < 2ms**

### 4. TBP Protocol (`shared/protocol/tbp_spec.md`)

Binary UDP protocol. Packet = 8-byte header + payload.

Key design decisions:
- **bincode v2** for zero-copy deserialization
- **Little-endian** integers (matches x86/ARM)
- **Sequence numbers** for duplicate detection
- **AES-128-GCM** with ECDH key exchange (X25519)
- **mDNS** for zero-config discovery

### 5. Input Injection

| Platform | API | Permission |
|----------|-----|------------|
| macOS | `CGEventCreateMouseEvent` | Accessibility (System Settings) |
| Windows | `SendInput` | None (user-level) |

**macOS:** `AXIsProcessTrustedWithOptions()` checked at startup. If denied, onboarding dialog shown.

## Data Flow: Trackpad Mode

```
Thumb swipe on watch
  → SpatialEventGesture.onChanged (watchOS, ~16ms)
  → TouchPayload{x, y, phase=MOVED}
  → WCSession.sendMessage() (BT, ~3ms)
  → WatchRelayService.didReceiveMessage (iPhone, ~0.1ms)
  → UDPRelay.send() (Wi-Fi, ~2ms)
  → UdpServer.handle_packet() (Desktop, ~0.1ms)
  → Kalman2D.update(x, y) (~0.05ms)
  → apply_curve_2d(dx, dy) (~0.01ms)
  → CGEventPost(kCGEventMouseMoved) (~1ms)
  → Cursor moves on screen
Total: ~7ms typical, ~20ms worst case
```

## Data Flow: Trackball Mode

```
Thumb fling on watch
  → GestureRecognizer detects FLING (on-watch)
  → GesturePayload{FLING, vx, vy}
  → [same relay path as above]
  → TrackballState.fling(vx, vy)
  → 16ms tokio::time::interval tick
  → TrackballState.tick() → (dx, dy)
  → apply_curve_2d(dx, dy)
  → CGEventPost(kCGEventMouseMoved)
  → Cursor coasts with friction decay (v *= 0.92/frame)
```

## Security

1. **Pairing:** X25519 ECDH ephemeral key exchange at session start
2. **Encryption:** AES-128-GCM, header as AAD
3. **Key derivation:** HKDF-SHA256, salt = "TBP-v1"
4. **Local network only:** UDP to LAN IP, no cloud relay
5. **No elevation:** Windows injection requires no admin rights

## Configuration

Config file location:
- macOS: `~/Library/Application Support/TrackBallWatch/config.json`
- Windows: `%APPDATA%\TrackBallWatch\config.json`

Key settings: `sensitivity`, `mode` (trackpad/trackball), `hand` (left/right), `accel.curve`, `trackball_friction`, `udp_port`.
