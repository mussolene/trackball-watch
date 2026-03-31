#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MotionDecision {
    Applied,
    Deadzone,
    ZeroOutput,
}

#[derive(Debug, Clone, Copy)]
pub struct MotionTelemetry {
    pub input_dx: f64,
    pub input_dy: f64,
    pub input_speed: f64,
    pub gain: f64,
    pub output_dx: f64,
    pub output_dy: f64,
    pub decision: MotionDecision,
}

#[derive(Debug, Clone, Copy)]
pub struct VirtualBallConfig {
    pub packet_scale: f64,
    pub fine_gain: f64,
    pub roll_gain: f64,
    pub jitter_deadzone: f64,
    pub precision_speed: f64,
    pub travel_speed: f64,
    pub max_step: f64,
}

impl VirtualBallConfig {
    pub fn decode_axis(self, raw: i16) -> f64 {
        raw as f64 / self.packet_scale
    }

    pub fn gain_for_speed(self, speed: f64) -> f64 {
        if speed <= self.precision_speed {
            return self.fine_gain;
        }
        if speed >= self.travel_speed {
            return self.roll_gain;
        }

        let span = (self.travel_speed - self.precision_speed).max(f64::EPSILON);
        let t = ((speed - self.precision_speed) / span).clamp(0.0, 1.0);
        self.fine_gain + (self.roll_gain - self.fine_gain) * t
    }

    pub fn process_delta(self, dx: f64, dy: f64) -> MotionTelemetry {
        let speed = (dx * dx + dy * dy).sqrt();
        let gain = self.gain_for_speed(speed);
        if speed < self.jitter_deadzone {
            return MotionTelemetry {
                input_dx: dx,
                input_dy: dy,
                input_speed: speed,
                gain,
                output_dx: 0.0,
                output_dy: 0.0,
                decision: MotionDecision::Deadzone,
            };
        }

        let sx = (dx * gain).clamp(-self.max_step, self.max_step);
        let sy = (dy * gain).clamp(-self.max_step, self.max_step);
        let decision = if sx * sx + sy * sy < 1e-8 {
            MotionDecision::ZeroOutput
        } else {
            MotionDecision::Applied
        };
        MotionTelemetry {
            input_dx: dx,
            input_dy: dy,
            input_speed: speed,
            gain,
            output_dx: sx,
            output_dy: sy,
            decision,
        }
    }

    pub fn cursor_delta(self, dx: f64, dy: f64) -> Option<(f64, f64)> {
        let telemetry = self.process_delta(dx, dy);
        match telemetry.decision {
            MotionDecision::Applied => Some((telemetry.output_dx, telemetry.output_dy)),
            MotionDecision::Deadzone | MotionDecision::ZeroOutput => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{MotionDecision, VirtualBallConfig};

    const CFG: VirtualBallConfig = VirtualBallConfig {
        packet_scale: 32.0,
        fine_gain: 0.25,
        roll_gain: 0.5,
        jitter_deadzone: 0.02,
        precision_speed: 0.12,
        travel_speed: 1.0,
        max_step: 24.0,
    };

    #[test]
    fn decode_axis_preserves_fractional_precision() {
        assert!((CFG.decode_axis(1) - (1.0 / 32.0)).abs() < 1e-9);
        assert!((CFG.decode_axis(-3) + (3.0 / 32.0)).abs() < 1e-9);
    }

    #[test]
    fn cursor_delta_ignores_jitter() {
        assert_eq!(CFG.cursor_delta(0.01, 0.0), None);
    }

    #[test]
    fn cursor_delta_scales_surface_motion() {
        let (dx, dy) = CFG.cursor_delta(2.0, -4.0).unwrap();
        assert!((dx - 1.0).abs() < 1e-9);
        assert!((dy + 2.0).abs() < 1e-9);
    }

    #[test]
    fn cursor_delta_uses_lower_gain_for_slow_precision_motion() {
        let (dx, dy) = CFG.cursor_delta(0.1, 0.0).unwrap();
        assert!((dx - 0.025).abs() < 1e-9);
        assert!(dy.abs() < 1e-9);
    }

    #[test]
    fn gain_blends_from_precision_to_travel() {
        let low = CFG.gain_for_speed(0.1);
        let mid = CFG.gain_for_speed(0.56);
        let high = CFG.gain_for_speed(2.0);
        assert!(
            low < mid && mid < high,
            "unexpected gain profile: low={low}, mid={mid}, high={high}"
        );
        assert!((high - CFG.roll_gain).abs() < 1e-9);
    }

    #[test]
    fn telemetry_marks_deadzone_samples() {
        let telemetry = CFG.process_delta(0.01, 0.0);
        assert_eq!(telemetry.decision, MotionDecision::Deadzone);
        assert_eq!(telemetry.output_dx, 0.0);
        assert_eq!(telemetry.output_dy, 0.0);
    }

    #[test]
    fn telemetry_reports_gain_and_output_for_applied_motion() {
        let telemetry = CFG.process_delta(0.5, -0.25);
        assert_eq!(telemetry.decision, MotionDecision::Applied);
        assert!(telemetry.gain >= CFG.fine_gain && telemetry.gain <= CFG.roll_gain);
        assert!(telemetry.output_dx > 0.0);
        assert!(telemetry.output_dy < 0.0);
    }

    #[test]
    fn cursor_delta_clamps_large_motion() {
        let (dx, dy) = CFG.cursor_delta(200.0, -200.0).unwrap();
        assert_eq!(dx, 24.0);
        assert_eq!(dy, -24.0);
    }
}
