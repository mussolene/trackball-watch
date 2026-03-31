use crate::protocol::packets::{TouchPayload, TouchPhase};

use super::virtual_ball::{MotionDecision, MotionTelemetry, VirtualBallConfig};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DriverMode {
    Trackpad,
    Trackball,
}

#[derive(Debug, Clone, Copy)]
pub struct DriverOutput {
    pub dx: f64,
    pub dy: f64,
    pub telemetry: MotionTelemetry,
}

const TRACKPAD_BALL_CONFIG: VirtualBallConfig = VirtualBallConfig {
    packet_scale: 400.0,
    fine_gain: 0.42,
    roll_gain: 0.85,
    jitter_deadzone: 0.006,
    precision_speed: 0.08,
    travel_speed: 0.75,
    max_step: 28.0,
};

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
    last_raw_x: f64,
    last_raw_y: f64,
    last_packet_x: i16,
    last_packet_y: i16,
}

impl PointingDeviceState {
    pub fn reset(&mut self) {
        self.last_raw_x = 0.0;
        self.last_raw_y = 0.0;
        self.last_packet_x = 0;
        self.last_packet_y = 0;
    }

    pub fn handle_touch(
        &mut self,
        mode: DriverMode,
        payload: TouchPayload,
    ) -> Option<DriverOutput> {
        let phase = TouchPhase::try_from(payload.phase).unwrap_or(TouchPhase::Moved);
        if matches!(phase, TouchPhase::Ended | TouchPhase::Cancelled) {
            self.reset();
            return None;
        }

        let config = match mode {
            DriverMode::Trackpad => TRACKPAD_BALL_CONFIG,
            DriverMode::Trackball => TRACKBALL_BALL_CONFIG,
        };
        let x = config.decode_axis(payload.x);
        let y = config.decode_axis(payload.y);

        if phase == TouchPhase::Began {
            self.last_raw_x = x;
            self.last_raw_y = y;
            self.last_packet_x = payload.x;
            self.last_packet_y = payload.y;
            return None;
        }

        let (dx, dy) = match mode {
            DriverMode::Trackpad => (x - self.last_raw_x, y - self.last_raw_y),
            DriverMode::Trackball => {
                let raw_dx = wrapped_i16_delta(payload.x, self.last_packet_x) as f64;
                let raw_dy = wrapped_i16_delta(payload.y, self.last_packet_y) as f64;
                (raw_dx / config.packet_scale, raw_dy / config.packet_scale)
            }
        };
        self.last_raw_x = x;
        self.last_raw_y = y;
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

    pub fn config_for(mode: DriverMode) -> VirtualBallConfig {
        match mode {
            DriverMode::Trackpad => TRACKPAD_BALL_CONFIG,
            DriverMode::Trackball => TRACKBALL_BALL_CONFIG,
        }
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
        let cfg = PointingDeviceState::config_for(DriverMode::Trackball);
        assert!((cfg.decode_axis(1) - (1.0 / 32.0)).abs() < 1e-9);
        assert!((cfg.decode_axis(-3) + (3.0 / 32.0)).abs() < 1e-9);
    }

    #[test]
    fn trackball_touch_emits_fractional_cursor_delta() {
        let mut state = PointingDeviceState::default();
        assert_eq!(state.handle_touch(DriverMode::Trackball, touch_payload(TouchPhase::Began, 0, 0)).is_some(), false);
        let output = state
            .handle_touch(DriverMode::Trackball, touch_payload(TouchPhase::Moved, 2, 0))
            .expect("fractional movement expected");
        assert!(output.dx > 0.01 && output.dx < 0.02, "unexpected dx: {}", output.dx);
        assert!(output.dy.abs() < 1e-9);
    }

    #[test]
    fn trackpad_uses_same_virtual_ball_kinematics_without_inertia() {
        let mut state = PointingDeviceState::default();
        assert_eq!(state.handle_touch(DriverMode::Trackpad, touch_payload(TouchPhase::Began, 0, 0)).is_some(), false);
        let output = state
            .handle_touch(DriverMode::Trackpad, touch_payload(TouchPhase::Moved, 200, 0))
            .expect("surface movement expected");
        assert!(output.dx > 0.2 && output.dx < 0.5, "unexpected dx: {}", output.dx);
        assert!(output.dy.abs() < 1e-9);
        assert_eq!(state.handle_touch(DriverMode::Trackpad, touch_payload(TouchPhase::Ended, 200, 0)).is_some(), false);
    }

    #[test]
    fn trackpad_stops_when_surface_delta_becomes_zero() {
        let mut state = PointingDeviceState::default();
        assert_eq!(state.handle_touch(DriverMode::Trackpad, touch_payload(TouchPhase::Began, 0, 0)).is_some(), false);
        let first = state.handle_touch(DriverMode::Trackpad, touch_payload(TouchPhase::Moved, 120, 0));
        let second = state.handle_touch(DriverMode::Trackpad, touch_payload(TouchPhase::Moved, 120, 0));
        assert!(first.is_some());
        assert!(second.is_none());
    }

    #[test]
    fn trackball_wraps_packet_boundary_without_cursor_jump() {
        let mut state = PointingDeviceState::default();
        assert_eq!(
            state
                .handle_touch(
                    DriverMode::Trackball,
                    touch_payload(TouchPhase::Began, i16::MAX - 2, 0)
                )
                .is_some(),
            false
        );
        let output = state
            .handle_touch(DriverMode::Trackball, touch_payload(TouchPhase::Moved, i16::MIN + 2, 0))
            .expect("wrapped movement expected");
        assert!(output.dx > 0.01, "wrapped dx must stay positive and small, got {}", output.dx);
        assert!(output.dx < 0.2, "wrapped dx must not create a large jump, got {}", output.dx);
        assert!(output.dy.abs() < 1e-9);
    }
}
