use crate::protocol::packets::{TouchPayload, TouchPhase};
use crate::trace_file;

use super::virtual_ball::{MotionDecision, MotionTelemetry, VirtualBallConfig};

const DEFAULT_MOTION_DEBUG: bool = false;

#[derive(Debug, Clone, Copy)]
pub struct DriverOutput {
    pub dx: f64,
    pub dy: f64,
    pub telemetry: MotionTelemetry,
}

const TRACKBALL_BALL_CONFIG: VirtualBallConfig = VirtualBallConfig {
    packet_scale: 32.0,
    fine_gain: 0.28,
    roll_gain: 0.48,
    jitter_deadzone: 0.008,
    precision_speed: 0.05,
    travel_speed: 0.50,
    max_step: 22.0,
};

#[derive(Debug, Clone, Default)]
pub struct PointingDeviceState {
    last_packet_x: i16,
    last_packet_y: i16,
    last_seq: Option<u16>,
}

impl PointingDeviceState {
    pub fn reset(&mut self) {
        self.last_packet_x = 0;
        self.last_packet_y = 0;
        self.last_seq = None;
    }

    pub fn accept_sequence(&mut self, seq: u16) -> bool {
        let accepted = match self.last_seq {
            None => true,
            Some(prev) => is_newer_packet(seq, prev),
        };
        if accepted {
            self.last_seq = Some(seq);
        }
        accepted
    }

    pub fn handle_touch(&mut self, payload: TouchPayload) -> Option<DriverOutput> {
        let motion_debug = std::env::var("TRACKBALL_DEBUG_MOTION")
            .map(|v| v != "0")
            .unwrap_or(DEFAULT_MOTION_DEBUG);
        let phase = TouchPhase::try_from(payload.phase).unwrap_or(TouchPhase::Moved);
        if matches!(phase, TouchPhase::Ended | TouchPhase::Cancelled) {
            self.reset();
            return None;
        }

        let config = TRACKBALL_BALL_CONFIG;

        if phase == TouchPhase::Began {
            self.last_packet_x = payload.x;
            self.last_packet_y = payload.y;
            return None;
        }

        let raw_dx = wrapped_i16_delta(payload.x, self.last_packet_x) as f64;
        let raw_dy = wrapped_i16_delta(payload.y, self.last_packet_y) as f64;
        if motion_debug {
            log::debug!(
                "trackball decode: prev=({}, {}) curr=({}, {}) wrapped_delta=({}, {}) packet_scale={}",
                self.last_packet_x,
                self.last_packet_y,
                payload.x,
                payload.y,
                raw_dx,
                raw_dy,
                config.packet_scale
            );
            trace_file::append_line(format!(
                "trackball decode prev=({}, {}) curr=({}, {}) wrapped_delta=({}, {}) scale={}",
                self.last_packet_x,
                self.last_packet_y,
                payload.x,
                payload.y,
                raw_dx,
                raw_dy,
                config.packet_scale
            ));
        }
        let dx = raw_dx / config.packet_scale;
        let dy = raw_dy / config.packet_scale;
        self.last_packet_x = payload.x;
        self.last_packet_y = payload.y;

        // Trackball: same speed-dependent gain as trackpad (slow = precise, fast = travel),
        // so finger roll maps to cursor like a mechanical ball, not raw surface deltas.
        let telemetry = config.process_delta(dx, dy);
        match telemetry.decision {
            MotionDecision::Applied => Some(DriverOutput {
                dx: telemetry.output_dx,
                dy: telemetry.output_dy,
                telemetry,
            }),
            MotionDecision::Deadzone | MotionDecision::ZeroOutput => None,
        }
    }

    pub fn trackball_config() -> VirtualBallConfig {
        TRACKBALL_BALL_CONFIG
    }
}

fn wrapped_i16_delta(curr: i16, prev: i16) -> i32 {
    let mut d = i32::from(curr) - i32::from(prev);
    if d > i32::from(i16::MAX) {
        d -= 1 << 16;
    } else if d < i32::from(i16::MIN) {
        d += 1 << 16;
    }
    d
}

fn is_newer_packet(seq: u16, prev: u16) -> bool {
    let delta = seq.wrapping_sub(prev);
    delta != 0 && delta < 0x8000
}

#[cfg(test)]
mod tests {
    use super::*;

    fn touch_payload(phase: TouchPhase, x: i16, y: i16) -> TouchPayload {
        TouchPayload {
            touch_id: 0,
            phase: phase as u8,
            x,
            y,
            pressure: 0,
            _pad: 0,
        }
    }

    #[test]
    fn trackball_preserves_fractional_precision() {
        let cfg = PointingDeviceState::trackball_config();
        assert!((cfg.decode_axis(1) - (1.0 / 32.0)).abs() < 1e-9);
        assert!((cfg.decode_axis(-3) + (3.0 / 32.0)).abs() < 1e-9);
    }

    #[test]
    fn trackball_touch_emits_fractional_cursor_delta() {
        let mut state = PointingDeviceState::default();
        assert_eq!(
            state
                .handle_touch(touch_payload(TouchPhase::Began, 0, 0))
                .is_some(),
            false
        );
        let output = state
            .handle_touch(touch_payload(TouchPhase::Moved, 2, 0))
            .expect("fractional movement expected");
        assert!(
            output.dx > 0.01 && output.dx < 0.02,
            "unexpected dx: {}",
            output.dx
        );
        assert!(output.dy.abs() < 1e-9);
    }

    #[test]
    fn trackball_wraps_packet_boundary_without_cursor_jump() {
        let mut state = PointingDeviceState::default();
        assert_eq!(
            state
                .handle_touch(touch_payload(TouchPhase::Began, i16::MAX - 2, 0))
                .is_some(),
            false
        );
        let output = state
            .handle_touch(touch_payload(TouchPhase::Moved, i16::MIN + 2, 0))
            .expect("wrapped movement expected");
        assert!(
            output.dx > 0.01,
            "wrapped dx must stay positive and small, got {}",
            output.dx
        );
        assert!(
            output.dx < 0.2,
            "wrapped dx must not create a large jump, got {}",
            output.dx
        );
        assert!(output.dy.abs() < 1e-9);
    }

    #[test]
    fn sequence_filter_rejects_duplicates_and_older_packets() {
        let mut state = PointingDeviceState::default();
        assert!(state.accept_sequence(10));
        assert!(!state.accept_sequence(10));
        assert!(state.accept_sequence(11));
        assert!(!state.accept_sequence(9));
    }

    #[test]
    fn sequence_filter_accepts_wraparound() {
        let mut state = PointingDeviceState::default();
        assert!(state.accept_sequence(u16::MAX));
        assert!(state.accept_sequence(0));
        assert!(state.accept_sequence(1));
    }
}
