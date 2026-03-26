---
name: trackball-watch-dev
description: >-
  Development workflow for the TrackBall Watch project — an Apple Watch trackball/trackpad
  for desktop cursor control. Use when building, running, testing, debugging, or modifying
  any component: Rust desktop host (Tauri), Swift watch/iOS apps, Svelte frontend, or
  the TBP protocol. Covers architecture, build commands, code patterns, and common pitfalls.
---

# TrackBall Watch — Developer Skill

## Quick Reference

```
make dev            # Run desktop host with hot-reload
make build          # Build ALL targets (desktop + iOS + watchOS + tools)
make test           # Run ALL tests (Rust + Swift)
make lint           # cargo fmt --check + clippy -D warnings
make check          # Fast cargo check (no link)
make xcodegen       # Regenerate .xcodeproj from project.yml
make help           # Show all targets
```

## Architecture at a Glance

```
Watch (Swift, SpatialEventGesture)
  → WatchConnectivity BT (~3ms)
  → iPhone relay (Swift, NWConnection UDP)
  → Wi-Fi UDP :47474 (~2ms)
  → Desktop host (Rust/Tauri)
      → TBP decode (bincode v2)
      → Kalman2D filter → AccelCurve → InputInjector (CGEvent/SendInput)
```

## Repo Layout

| Path | What | Build |
|------|------|-------|
| `apps/host-desktop/` | Tauri 2 + Svelte 5 + Vite 6 frontend | `make dev` / `make build-desktop` |
| `apps/host-desktop/src-tauri/` | Rust backend (tokio UDP, crypto, Kalman, injection) | `cargo test --all-features` |
| `apps/watch-ios/` | Watch app + iOS companion (single .xcodeproj) | `make build-ios` / `make build-watch` |
| `apps/companion-ios/` | Standalone iPhone relay | `make build-companion` |
| `shared/protocol/tbp_spec.md` | TBP binary protocol spec | reference only |
| `tools/latency-tester/` | Rust CLI for RTT benchmarks | `make build-tools` |

## Working with Rust (Desktop Host)

### Module Map

```
src-tauri/src/
├── lib.rs              Tauri setup, AppState, event dispatch
├── engine/
│   ├── kalman.rs       2D Kalman filter [x, y, vx, vy]
│   ├── accel.rs        Acceleration curves (Linear/Quadratic/SCurve)
│   ├── trackball.rs    Fling physics with friction decay
│   └── gestures.rs     GestureType enum
├── protocol/
│   ├── packets.rs      TBP encode/decode (bincode v2, little-endian)
│   └── crypto.rs       AES-128-GCM, X25519 ECDH, HKDF
├── server/
│   ├── udp.rs          Tokio UDP server on port 47474
│   ├── connection.rs   Session state machine
│   └── mdns.rs         mDNS _tbp._udp.local registration
├── injector/
│   ├── platform.rs     InputInjector trait + InjectorError
│   ├── macos.rs        CGEvent (needs Accessibility)
│   ├── windows.rs      SendInput
│   └── linux.rs        stub
└── settings/
    ├── config.rs       AppConfig serde + file I/O
    └── profiles.rs     Built-in presets
```

### Key Rules

- `cargo fmt` before every commit; CI rejects unformatted code
- `cargo clippy -- -D warnings` — zero warnings in CI
- Hot path (Touch → Kalman → inject) must be allocation-free
- Platform-specific code only in `injector/` submodules
- Feature flag `testing` enables proptest in lib
- Config: macOS `~/Library/Application Support/TrackBallWatch/config.json`

### Common Tasks

**Add a new packet type:**
1. Add constant to `protocol::packets::packet_type`
2. Define payload struct with `#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]`
3. Implement `encode_*` / `decode_*` functions
4. Add proptest round-trip test
5. Handle in `UdpServer::parse_packet` match arm
6. Update `shared/protocol/tbp_spec.md`

**Add a new acceleration curve:**
1. Add variant to `engine::accel::CurveType`
2. Implement arm in `apply_curve()`
3. Add test verifying monotonicity / sign preservation
4. Update `settings::profiles` if adding a preset

## Working with Swift (iOS / watchOS)

### Key Files

| Watch App | Role |
|-----------|------|
| `InputCaptureView.swift` | Full-screen SpatialEventGesture |
| `GestureRecognizer.swift` | On-device tap/fling classification |
| `WatchSessionManager.swift` | WCSession.sendMessage() |
| `TBPPacket.swift` | LE packet serializer (must match tbp_spec.md) |
| `CrownHandler.swift` | Crown → CROWN packets |

| Companion | Role |
|-----------|------|
| `WatchRelayService.swift` | WCSession → UDP bridge |
| `UDPRelay.swift` | NWConnection to desktop |
| `PairingService.swift` | QR scan → config storage |
| `BonjourBrowser.swift` | mDNS _tbp._udp.local discovery |

### Key Rules

- Coordinates: normalize CGPoint → -32767..32767
- Gesture recognition runs ON WATCH to reduce BT traffic
- Two Xcode projects; use `make xcodegen` after editing `project.yml`
- Local signing config: `Local.xcconfig` (gitignored) — see `Local.xcconfig.example`
- Build without signing: `make build-ios` (uses CODE_SIGNING_REQUIRED=NO)

## Working with Svelte (Frontend UI)

```
apps/host-desktop/src/
├── App.svelte
├── components/
│   ├── Settings.svelte     ← maps 1:1 to AppConfig Rust struct
│   └── StatusBar.svelte
```

- Svelte **5** runes: `$state`, `$derived`, `$effect` — no legacy `$:`
- Tauri IPC: `invoke('get_config')`, `invoke('save_config', { config })`
- Vite dev server on port **1420**

## TBP Protocol Essentials

- UDP port **47474**, mDNS `_tbp._udp.local`
- 8-byte header: `seq(u16) | type(u8) | flags(u8) | timestamp_us(u32)` — all LE
- Packet types: TOUCH=0x01, GESTURE=0x02, CROWN=0x03, HANDSHAKE=0x10, HEARTBEAT=0x11
- Encryption: AES-128-GCM, nonce = seq(4) + timestamp(8), AAD = header
- Heartbeat timeout: 3s → session drop

## Common Pitfalls

1. **`cargo` not found** — run `source ~/.cargo/env` or use `make` (sets PATH)
2. **npm peer deps conflict** — `@sveltejs/vite-plugin-svelte` version must match Vite major
3. **Xcode build fails after editing project.yml** — run `make xcodegen`
4. **Cursor doesn't move (macOS)** — grant Accessibility permission to TrackBall Watch
5. **DEVELOPMENT_TEAM errors** — copy `Local.xcconfig.example` → `Local.xcconfig`, set your team ID
6. **Icon missing** — Assets.xcassets in source dirs; regenerate project with `make xcodegen`
