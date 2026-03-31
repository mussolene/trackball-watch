# Changelog

All notable changes to TrackBall Watch will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.3] - 2026-03-31

### Fixed

- **Desktop / CI:** `sync-version-from-git.mjs` runs `cargo check` without a Vite build; ensure a stub `dist/index.html` on CI and align paths with `frontendDist`. On Windows runners, enable `windows` crate feature `Win32_UI_WindowsAndMessaging` for `GetSystemMetrics` in absolute mouse move.

## [1.0.2] - 2026-03-31

### Fixed

- **iOS Companion:** Trackball Remote finger marker used full-panel geometry while `DragGesture` reports positions in the inner `outerDiameter` ZStack — convert using the globe inset and align the hit test so the dot matches the visible sphere.

## [1.0.1] - 2026-03-31

### Fixed

- **macOS:** Desktop bundle id was `com.trackball-watch.app` (`.app` suffix confuses the system), the main binary was linker-signed with **Info.plist not bound** to the code signature, and `entitlements.plist` was missing — together this broke TCC / Accessibility matching. Now: `com.trackballwatch.host`, executable `TrackBallWatch`, real entitlements, merged `NSAccessibilityUsageDescription`, and post-build `codesign` so the plist seals with the app (iOS bundle ids unchanged).
- **macOS:** Pointer injection (`CGEventPost`) runs on the AppKit main thread via `AppHandle::run_on_main_thread`; posting from the Tokio UDP thread often produced no cursor motion even when Accessibility was granted.

### Added

- **Desktop:** `check_accessibility` returns trusted flag plus resolved executable path; settings UI explains dev vs `/Applications` entries.
- **Desktop:** Single-instance (focus existing window), editable UDP port (restart required), Vite build step in `make build-desktop` after `make clean`, layout fixes for settings/pairing and status bar.

## [1.0.0] - 2026-03-26

### Added

#### Desktop Host (macOS + Windows)
- TBP (TrackBall Protocol) binary UDP protocol with bincode serialization
- AES-128-GCM encrypted sessions via X25519 ECDH pairing
- mDNS device discovery (`_tbp._udp.local`)
- 2D Kalman filter for touch input smoothing (Q_pos=0.1, Q_vel=1.0, R=0.5)
- S-curve (tanh) acceleration with configurable sensitivity and knee point
- Trackball inertia physics with friction-based velocity decay
- macOS input injection via CGEvent (requires Accessibility permission)
- Windows input injection via SendInput (no admin required)
- System tray UI with connection status indicator (green/yellow/red)
- Settings panel: mode, hand preference, sensitivity, acceleration curve
- JSON configuration persistence
- Built-in profiles: Precise, Default, Fast, Linear

#### Apple Watch App (watchOS 10+)
- Full-screen touch capture via `SpatialEventGesture`
- Touch coordinates normalized to -32767..32767
- On-device gesture recognition: tap, double-tap, long-press, swipe, fling
- Digital Crown → scroll events
- Long-press Crown → trackpad/trackball mode switch
- Haptic feedback on tap and gesture detection
- `WKExtendedRuntimeSession(.workout)` for background operation
- `WCSession.sendMessage()` with `transferUserInfo` fallback

#### iPhone Companion (iOS 16+)
- WatchConnectivity bridge: receives packets from watch and relays via UDP
- `NWConnection` UDP client to desktop host
- QR code pairing: scans `tbp://pair?host=&port=&id=` URL
- PushKit VoIP registration for background wakeup
- Connection status UI

#### CI/CD
- GitHub Actions CI: fmt + clippy + test + coverage (tarpaulin → codecov)
- Release workflow: macOS universal DMG + notarization, Windows MSI + signing
- TestFlight distribution for Watch + iPhone apps
- Property-based tests with proptest for packet round-trips

#### Tools
- `tools/latency-tester`: E2E RTT benchmark (p50/p95/p99 reporting)

### Technical Targets (Phase 1)
- Latency: p50 < 15ms, p99 < 30ms on Wi-Fi
- Session stability: 60+ minutes without disconnect
- Battery: 4+ hours continuous on Apple Watch 7
