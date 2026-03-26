# TrackBall Protocol (TBP) Specification

**Version:** 1.0
**Transport:** UDP (primary) / TCP (fallback)
**Discovery:** mDNS `_tbp._udp.local`
**Security:** AES-128-GCM, ECDH key exchange
**Default port:** 47474

---

## Overview

TBP is a low-latency binary protocol for transmitting touch, gesture, and crown events from a wearable device to a desktop host. Target end-to-end latency: p50 < 15ms, p99 < 30ms on Wi-Fi.

---

## Packet Structure

### Header (8 bytes, always present)

```
 0       1       2       3       4       5       6       7
 +-------+-------+-------+-------+-------+-------+-------+-------+
 | seq           | type  | flags | timestamp_us                  |
 +-------+-------+-------+-------+-------+-------+-------+-------+
```

| Field | Type | Description |
|-------|------|-------------|
| `seq` | u16 LE | Sequence number, wraps at 65535 |
| `type` | u8 | Packet type (see below) |
| `flags` | u8 | Bit flags (see below) |
| `timestamp_us` | u32 LE | Microseconds since session start |

### Flags byte

| Bit | Name | Description |
|-----|------|-------------|
| 0 | `ENCRYPTED` | Payload is AES-128-GCM encrypted |
| 1 | `COMPRESSED` | Payload is compressed (reserved) |
| 2-7 | reserved | Must be 0 |

---

## Packet Types

### 0x01 TOUCH (8 bytes payload)

Sent for each touch phase change. Coordinates normalized to -32767..32767.

```
 +-------+-------+-------+-------+-------+-------+-------+-------+
 |touch_id|phase  | x             | y             |pressure|_pad  |
 +-------+-------+-------+-------+-------+-------+-------+-------+
```

| Field | Type | Description |
|-------|------|-------------|
| `touch_id` | u8 | Finger identifier (0-9) |
| `phase` | u8 | `BEGAN=1, MOVED=2, ENDED=3, CANCELLED=4` |
| `x` | i16 LE | Normalized X: -32767 (left) .. 32767 (right) |
| `y` | i16 LE | Normalized Y: -32767 (top) .. 32767 (bottom) |
| `pressure` | u8 | Touch pressure 0-255 (0 if unavailable) |
| `_pad` | u8 | Padding, must be 0 |

### 0x02 GESTURE (6 bytes payload)

Sent when gesture recognizer on watch identifies a gesture.

```
 +-------+-------+-------+-------+-------+-------+
 | type  |fingers| param1        | param2        |
 +-------+-------+-------+-------+-------+-------+
```

| Field | Type | Description |
|-------|------|-------------|
| `type` | u8 | Gesture type (see below) |
| `fingers` | u8 | Number of fingers |
| `param1` | i16 LE | Gesture-specific parameter 1 |
| `param2` | i16 LE | Gesture-specific parameter 2 |

**Gesture types:**

| Value | Name | param1 | param2 |
|-------|------|--------|--------|
| 1 | `TAP` | 0 | 0 |
| 2 | `DOUBLE_TAP` | 0 | 0 |
| 3 | `LONG_PRESS` | duration_ms | 0 |
| 4 | `SWIPE` | direction (0=up,1=right,2=down,3=left) | distance |
| 5 | `FLING` | velocity_x (-32767..32767) | velocity_y |
| 6 | `PINCH` | scale * 1000 | 0 |

### 0x03 CROWN (4 bytes payload)

Digital Crown rotation event.

```
 +-------+-------+-------+-------+
 | delta         | velocity       |
 +-------+-------+-------+-------+
```

| Field | Type | Description |
|-------|------|-------------|
| `delta` | i16 LE | Rotation delta, arbitrary units |
| `velocity` | i16 LE | Rotation velocity |

### 0x10 HANDSHAKE (variable payload)

Initial connection establishment. Payload is ECDH public key (32 bytes) + device info JSON.

```
 +---32 bytes---+---variable---+
 | ecdh_pub_key | device_info  |
 +--------------+--------------+
```

`device_info` JSON fields: `device_id`, `device_name`, `app_version`, `platform`.

### 0x11 HEARTBEAT (0 bytes payload)

Sent every 500ms to keep connection alive. No payload.

### 0x20 PING (8 bytes payload)

```
 +-------+-------+-------+-------+-------+-------+-------+-------+
 | client_timestamp_us                                            |
 +-------+-------+-------+-------+-------+-------+-------+-------+
```

| Field | Type | Description |
|-------|------|-------------|
| `client_timestamp_us` | u64 LE | Client timestamp for RTT calculation |

### 0x21 PONG (8 bytes payload)

Same structure as PING. Desktop echoes client_timestamp_us unchanged.

---

## Session Lifecycle

```
Client                          Server
  |                               |
  |------ HANDSHAKE (0x10) ------>|
  |<----- HANDSHAKE (0x10) -------|  (server sends its pub key)
  |                               |  Both sides derive shared secret
  |                               |
  |==== Encrypted channel ========|
  |                               |
  |------ TOUCH/GESTURE/CROWN --->|  (continuous stream)
  |------ HEARTBEAT (500ms) ----->|
  |                               |
  |  [timeout: no heartbeat 3s]   |
  |                               |
  |------ HANDSHAKE again ------->|  (reconnect)
```

---

## Encryption

1. **Key Exchange:** X25519 ECDH
2. **Key Derivation:** HKDF-SHA256 from shared secret, salt = `"TBP-v1"`
3. **Encryption:** AES-128-GCM
4. **Nonce:** 12 bytes, first 4 = seq number (u32 LE), last 8 = timestamp_us (u64 LE)
5. **AAD:** Packet header (8 bytes)

---

## Serialization

All multi-byte integers are **little-endian**.
Rust serialization: `bincode` v2 with fixed-int encoding.

---

## Error Handling

- Out-of-order packets: ignore (UDP is best-effort)
- Duplicate seq numbers: ignore if within last 64 packets
- Heartbeat timeout (3s): close session, trigger reconnect UI
- Decryption failure: drop packet, log error

---

## Port and Discovery

**Default port:** 47474
**mDNS service type:** `_tbp._udp.local`
**mDNS TXT records:** `version=1`, `device_id=<uuid>`
