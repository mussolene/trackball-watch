//! TBP (TrackBall Protocol) packet definitions.
//!
//! All multi-byte integers are little-endian.
//! Packet structure: 8-byte header + variable payload.

use bincode::{Decode, Encode};
use serde::{Deserialize, Serialize};

// ── Header ───────────────────────────────────────────────────────────────────

/// 8-byte packet header, always present.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Encode, Decode, Serialize, Deserialize)]
pub struct PacketHeader {
    /// Sequence number, wraps at 65535.
    pub seq: u16,
    /// Packet type discriminant.
    pub packet_type: u8,
    /// Bit flags: bit 0 = ENCRYPTED, bit 1 = COMPRESSED (reserved).
    pub flags: u8,
    /// Microseconds since session start.
    pub timestamp_us: u32,
}

impl PacketHeader {
    pub const ENCRYPTED: u8 = 0b0000_0001;
    pub const COMPRESSED: u8 = 0b0000_0010;

    pub fn is_encrypted(self) -> bool {
        self.flags & Self::ENCRYPTED != 0
    }
}

// ── Touch ─────────────────────────────────────────────────────────────────────

/// Touch phase.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Encode, Decode, Serialize, Deserialize)]
#[repr(u8)]
pub enum TouchPhase {
    Began = 1,
    Moved = 2,
    Ended = 3,
    Cancelled = 4,
}

impl TryFrom<u8> for TouchPhase {
    type Error = u8;

    fn try_from(v: u8) -> Result<Self, Self::Error> {
        match v {
            1 => Ok(Self::Began),
            2 => Ok(Self::Moved),
            3 => Ok(Self::Ended),
            4 => Ok(Self::Cancelled),
            other => Err(other),
        }
    }
}

/// Packet type `0x01 TOUCH` — 8-byte payload.
///
/// Coordinates are normalized: -32767 (min) to 32767 (max).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Encode, Decode, Serialize, Deserialize)]
pub struct TouchPayload {
    pub touch_id: u8,
    pub phase: u8,
    /// Normalized X: -32767 (left) .. 32767 (right).
    pub x: i16,
    /// Normalized Y: -32767 (top) .. 32767 (bottom).
    pub y: i16,
    /// Touch pressure 0-255 (0 if unavailable).
    pub pressure: u8,
    pub _pad: u8,
}

// ── Gesture ───────────────────────────────────────────────────────────────────

/// Gesture type.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Encode, Decode, Serialize, Deserialize)]
#[repr(u8)]
pub enum GestureType {
    Tap = 1,
    DoubleTap = 2,
    LongPress = 3,
    Swipe = 4,
    Fling = 5,
    Pinch = 6,
}

impl TryFrom<u8> for GestureType {
    type Error = u8;

    fn try_from(v: u8) -> Result<Self, Self::Error> {
        match v {
            1 => Ok(Self::Tap),
            2 => Ok(Self::DoubleTap),
            3 => Ok(Self::LongPress),
            4 => Ok(Self::Swipe),
            5 => Ok(Self::Fling),
            6 => Ok(Self::Pinch),
            other => Err(other),
        }
    }
}

/// Swipe/fling direction.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum SwipeDirection {
    Up = 0,
    Right = 1,
    Down = 2,
    Left = 3,
}

/// Packet type `0x02 GESTURE` — 6-byte payload.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Encode, Decode, Serialize, Deserialize)]
pub struct GesturePayload {
    pub gesture_type: u8,
    pub fingers: u8,
    /// Gesture-specific parameter 1.
    /// - LONG_PRESS: duration_ms
    /// - SWIPE: direction (0=Up, 1=Right, 2=Down, 3=Left)
    /// - FLING: velocity_x (-32767..32767)
    /// - PINCH: scale * 1000
    pub param1: i16,
    /// Gesture-specific parameter 2.
    /// - SWIPE: distance
    /// - FLING: velocity_y
    pub param2: i16,
}

// ── Crown ─────────────────────────────────────────────────────────────────────

/// Packet type `0x03 CROWN` — 4-byte payload.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Encode, Decode, Serialize, Deserialize)]
pub struct CrownPayload {
    pub delta: i16,
    pub velocity: i16,
}

// ── Handshake ─────────────────────────────────────────────────────────────────

/// Packet type `0x10 HANDSHAKE` — variable payload.
/// ECDH public key (32 bytes) + device info JSON.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HandshakePayload {
    /// X25519 public key, 32 bytes.
    pub ecdh_pub_key: [u8; 32],
    pub device_id: String,
    pub device_name: String,
    pub app_version: String,
    /// "watchos", "ios", "android"
    pub platform: String,
}

// ── Packet type constants ──────────────────────────────────────────────────────

pub mod packet_type {
    pub const TOUCH: u8 = 0x01;
    pub const GESTURE: u8 = 0x02;
    pub const CROWN: u8 = 0x03;
    pub const HANDSHAKE: u8 = 0x10;
    pub const HEARTBEAT: u8 = 0x11;
    pub const PING: u8 = 0x20;
    pub const PONG: u8 = 0x21;
}

// ── Framed packet ─────────────────────────────────────────────────────────────

/// A decoded packet combining header and parsed payload.
#[derive(Debug, Clone, PartialEq)]
pub enum Packet {
    Touch {
        header: PacketHeader,
        payload: TouchPayload,
    },
    Gesture {
        header: PacketHeader,
        payload: GesturePayload,
    },
    Crown {
        header: PacketHeader,
        payload: CrownPayload,
    },
    Handshake {
        header: PacketHeader,
        payload: HandshakePayload,
    },
    Heartbeat {
        header: PacketHeader,
    },
    Ping {
        header: PacketHeader,
        /// Client timestamp for RTT calculation.
        client_timestamp_us: u64,
    },
    Pong {
        header: PacketHeader,
        client_timestamp_us: u64,
    },
}

impl Packet {
    pub fn header(&self) -> &PacketHeader {
        match self {
            Self::Touch { header, .. } => header,
            Self::Gesture { header, .. } => header,
            Self::Crown { header, .. } => header,
            Self::Handshake { header, .. } => header,
            Self::Heartbeat { header } => header,
            Self::Ping { header, .. } => header,
            Self::Pong { header, .. } => header,
        }
    }
}

// ── Codec ─────────────────────────────────────────────────────────────────────

use bincode::config::standard;

/// Encode a `PacketHeader` to bytes.
pub fn encode_header(header: &PacketHeader) -> Result<Vec<u8>, bincode::error::EncodeError> {
    bincode::encode_to_vec(header, standard())
}

/// Decode a `PacketHeader` from the first 8 bytes of a buffer.
pub fn decode_header(buf: &[u8]) -> Result<(PacketHeader, usize), bincode::error::DecodeError> {
    bincode::decode_from_slice(buf, standard())
}

/// Encode a `TouchPayload` to bytes.
pub fn encode_touch(payload: &TouchPayload) -> Result<Vec<u8>, bincode::error::EncodeError> {
    bincode::encode_to_vec(payload, standard())
}

pub fn decode_touch(buf: &[u8]) -> Result<(TouchPayload, usize), bincode::error::DecodeError> {
    bincode::decode_from_slice(buf, standard())
}

pub fn encode_gesture(payload: &GesturePayload) -> Result<Vec<u8>, bincode::error::EncodeError> {
    bincode::encode_to_vec(payload, standard())
}

pub fn decode_gesture(buf: &[u8]) -> Result<(GesturePayload, usize), bincode::error::DecodeError> {
    bincode::decode_from_slice(buf, standard())
}

pub fn encode_crown(payload: &CrownPayload) -> Result<Vec<u8>, bincode::error::EncodeError> {
    bincode::encode_to_vec(payload, standard())
}

pub fn decode_crown(buf: &[u8]) -> Result<(CrownPayload, usize), bincode::error::DecodeError> {
    bincode::decode_from_slice(buf, standard())
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_header(packet_type: u8) -> PacketHeader {
        PacketHeader {
            seq: 42,
            packet_type,
            flags: 0,
            timestamp_us: 123_456,
        }
    }

    #[test]
    fn header_round_trip() {
        let h = sample_header(packet_type::TOUCH);
        let bytes = encode_header(&h).unwrap();
        let (decoded, _) = decode_header(&bytes).unwrap();
        assert_eq!(h, decoded);
    }

    #[test]
    fn touch_round_trip() {
        let p = TouchPayload {
            touch_id: 0,
            phase: TouchPhase::Moved as u8,
            x: 12345,
            y: -9876,
            pressure: 200,
            _pad: 0,
        };
        let bytes = encode_touch(&p).unwrap();
        let (decoded, _) = decode_touch(&bytes).unwrap();
        assert_eq!(p, decoded);
    }

    #[test]
    fn touch_coordinate_extremes() {
        for (x, y) in [(i16::MIN, i16::MAX), (i16::MAX, i16::MIN), (0, 0)] {
            let p = TouchPayload {
                touch_id: 0,
                phase: 1,
                x,
                y,
                pressure: 0,
                _pad: 0,
            };
            let (decoded, _) = decode_touch(&encode_touch(&p).unwrap()).unwrap();
            assert_eq!(p, decoded);
        }
    }

    #[test]
    fn gesture_round_trip() {
        let p = GesturePayload {
            gesture_type: GestureType::Fling as u8,
            fingers: 1,
            param1: 15000,
            param2: -8000,
        };
        let bytes = encode_gesture(&p).unwrap();
        let (decoded, _) = decode_gesture(&bytes).unwrap();
        assert_eq!(p, decoded);
    }

    #[test]
    fn crown_round_trip() {
        let p = CrownPayload {
            delta: -256,
            velocity: 1024,
        };
        let bytes = encode_crown(&p).unwrap();
        let (decoded, _) = decode_crown(&bytes).unwrap();
        assert_eq!(p, decoded);
    }

    #[test]
    fn touch_phase_try_from() {
        assert_eq!(TouchPhase::try_from(1), Ok(TouchPhase::Began));
        assert_eq!(TouchPhase::try_from(4), Ok(TouchPhase::Cancelled));
        assert_eq!(TouchPhase::try_from(99), Err(99u8));
    }

    #[test]
    fn gesture_type_try_from() {
        assert_eq!(GestureType::try_from(5), Ok(GestureType::Fling));
        assert_eq!(GestureType::try_from(0), Err(0u8));
    }

    #[test]
    fn header_encrypted_flag() {
        let mut h = sample_header(packet_type::TOUCH);
        assert!(!h.is_encrypted());
        h.flags |= PacketHeader::ENCRYPTED;
        assert!(h.is_encrypted());
    }
}

// ── Property-based tests ───────────────────────────────────────────────────────

#[cfg(test)]
mod prop_tests {
    use super::*;
    use proptest::prelude::*;

    proptest! {
        #[test]
        fn header_round_trip_arbitrary(
            seq in any::<u16>(),
            packet_type in any::<u8>(),
            flags in 0u8..=3,
            timestamp_us in any::<u32>(),
        ) {
            let h = PacketHeader { seq, packet_type, flags, timestamp_us };
            let bytes = encode_header(&h).unwrap();
            let (decoded, _) = decode_header(&bytes).unwrap();
            prop_assert_eq!(h, decoded);
        }

        #[test]
        fn touch_round_trip_arbitrary(
            touch_id in any::<u8>(),
            phase in 1u8..=4,
            x in any::<i16>(),
            y in any::<i16>(),
            pressure in any::<u8>(),
        ) {
            let p = TouchPayload { touch_id, phase, x, y, pressure, _pad: 0 };
            let bytes = encode_touch(&p).unwrap();
            let (decoded, _) = decode_touch(&bytes).unwrap();
            prop_assert_eq!(p, decoded);
        }

        #[test]
        fn gesture_round_trip_arbitrary(
            gesture_type in 1u8..=6,
            fingers in 1u8..=5,
            param1 in any::<i16>(),
            param2 in any::<i16>(),
        ) {
            let p = GesturePayload { gesture_type, fingers, param1, param2 };
            let bytes = encode_gesture(&p).unwrap();
            let (decoded, _) = decode_gesture(&bytes).unwrap();
            prop_assert_eq!(p, decoded);
        }

        #[test]
        fn crown_round_trip_arbitrary(
            delta in any::<i16>(),
            velocity in any::<i16>(),
        ) {
            let p = CrownPayload { delta, velocity };
            let bytes = encode_crown(&p).unwrap();
            let (decoded, _) = decode_crown(&bytes).unwrap();
            prop_assert_eq!(p, decoded);
        }
    }
}
