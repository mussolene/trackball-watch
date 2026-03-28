//! Acceleration curves for cursor movement.
//!
//! Transforms raw touch delta into screen delta with configurable curves.

/// Acceleration curve type.
#[derive(Debug, Clone, Copy, Default, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CurveType {
    /// Linear: out = sensitivity * delta
    Linear,
    /// Quadratic: out = sensitivity * delta^2 * sign(delta)
    Quadratic,
    /// S-curve (tanh): out = sensitivity * tanh(delta / knee) * max_delta
    #[default]
    SCurve,
}

/// Parameters for acceleration curves.
#[derive(Debug, Clone, Copy, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct AccelConfig {
    pub curve: CurveType,
    /// Overall sensitivity multiplier (0.1 – 5.0, default 1.0).
    pub sensitivity: f64,
    /// S-curve knee point: controls the transition from slow to fast.
    /// Smaller = more aggressive acceleration. Default: 5.0
    pub knee_point: f64,
    /// S-curve maximum output delta per frame (pixels). Default: 40.0
    pub max_delta: f64,
}

impl Default for AccelConfig {
    fn default() -> Self {
        Self {
            curve: CurveType::SCurve,
            sensitivity: 1.0,
            knee_point: 5.0,
            max_delta: 40.0,
        }
    }
}

/// Apply the acceleration curve to a 1D delta value.
///
/// `delta` — raw touch delta (normalized coordinates).
/// Returns screen pixels to move.
pub fn apply_curve(delta: f64, cfg: &AccelConfig) -> f64 {
    match cfg.curve {
        CurveType::Linear => cfg.sensitivity * delta,

        CurveType::Quadratic => cfg.sensitivity * delta * delta.abs(),

        CurveType::SCurve => {
            // out = sensitivity * tanh(delta / knee_point) * max_delta
            cfg.sensitivity * (delta / cfg.knee_point).tanh() * cfg.max_delta
        }
    }
}

/// Apply acceleration curve to a 2D (dx, dy) vector.
///
/// The curve is applied to the **magnitude** of the vector to preserve direction.
/// Applying it independently to each axis causes 8-direction snapping with tanh saturation.
pub fn apply_curve_2d(dx: f64, dy: f64, cfg: &AccelConfig) -> (f64, f64) {
    let mag = (dx * dx + dy * dy).sqrt();
    if mag < 1e-9 {
        return (0.0, 0.0);
    }
    let out_mag = apply_curve(mag, cfg);
    let scale = out_mag / mag;
    (dx * scale, dy * scale)
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn linear_scales_with_sensitivity() {
        let cfg = AccelConfig {
            curve: CurveType::Linear,
            sensitivity: 2.0,
            ..Default::default()
        };
        assert!((apply_curve(5.0, &cfg) - 10.0).abs() < 1e-9);
        assert!((apply_curve(-3.0, &cfg) - (-6.0)).abs() < 1e-9);
    }

    #[test]
    fn quadratic_preserves_sign() {
        let cfg = AccelConfig {
            curve: CurveType::Quadratic,
            sensitivity: 1.0,
            ..Default::default()
        };
        assert!(apply_curve(3.0, &cfg) > 0.0);
        assert!(apply_curve(-3.0, &cfg) < 0.0);
        assert!((apply_curve(3.0, &cfg) - 9.0).abs() < 1e-9);
    }

    #[test]
    fn scurve_bounded_by_max_delta() {
        let cfg = AccelConfig::default(); // max_delta = 40.0
        let out = apply_curve(1000.0, &cfg); // very large delta
        assert!(out <= cfg.max_delta * cfg.sensitivity + 1e-9);
        assert!(out >= 0.0);
    }

    #[test]
    fn scurve_antisymmetric() {
        let cfg = AccelConfig::default();
        let pos = apply_curve(10.0, &cfg);
        let neg = apply_curve(-10.0, &cfg);
        assert!((pos + neg).abs() < 1e-9, "S-curve should be antisymmetric");
    }

    #[test]
    fn scurve_zero_input_gives_zero() {
        let cfg = AccelConfig::default();
        assert!(apply_curve(0.0, &cfg).abs() < 1e-9);
    }

    #[test]
    fn scurve_monotonically_increasing() {
        let cfg = AccelConfig::default();
        let mut prev = f64::NEG_INFINITY;
        for i in 0..=50 {
            let v = apply_curve(i as f64 * 0.5, &cfg);
            assert!(v >= prev, "should be monotonic at i={}", i);
            prev = v;
        }
    }

    #[test]
    fn apply_curve_2d_preserves_direction() {
        let cfg = AccelConfig::default();
        // Magnitude-preserving: direction should be unchanged
        let (ox, oy) = apply_curve_2d(3.0, -4.0, &cfg);  // magnitude = 5
        let out_mag = (ox * ox + oy * oy).sqrt();
        let expected_mag = apply_curve(5.0, &cfg);
        assert!((out_mag - expected_mag).abs() < 1e-9, "magnitude: {} vs {}", out_mag, expected_mag);
        // Direction preserved: ratio should match input
        assert!((ox / oy - 3.0 / -4.0).abs() < 1e-9, "direction not preserved");
    }

    #[test]
    fn apply_curve_2d_zero_gives_zero() {
        let cfg = AccelConfig::default();
        let (ox, oy) = apply_curve_2d(0.0, 0.0, &cfg);
        assert_eq!((ox, oy), (0.0, 0.0));
    }
}
