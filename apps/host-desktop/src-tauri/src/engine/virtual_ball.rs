#[derive(Debug, Clone, Copy)]
pub struct VirtualBallConfig {
    pub packet_scale: f64,
    pub roll_gain: f64,
    pub jitter_deadzone: f64,
    pub max_step: f64,
}

impl VirtualBallConfig {
    pub fn decode_axis(self, raw: i16) -> f64 {
        raw as f64 / self.packet_scale
    }

    pub fn cursor_delta(self, dx: f64, dy: f64) -> Option<(f64, f64)> {
        let speed = (dx * dx + dy * dy).sqrt();
        if speed < self.jitter_deadzone {
            return None;
        }

        let sx = (dx * self.roll_gain).clamp(-self.max_step, self.max_step);
        let sy = (dy * self.roll_gain).clamp(-self.max_step, self.max_step);
        if sx * sx + sy * sy < 1e-8 {
            return None;
        }
        Some((sx, sy))
    }
}

#[cfg(test)]
mod tests {
    use super::VirtualBallConfig;

    const CFG: VirtualBallConfig = VirtualBallConfig {
        packet_scale: 32.0,
        roll_gain: 0.5,
        jitter_deadzone: 0.02,
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
    fn cursor_delta_clamps_large_motion() {
        let (dx, dy) = CFG.cursor_delta(200.0, -200.0).unwrap();
        assert_eq!(dx, 24.0);
        assert_eq!(dy, -24.0);
    }
}
