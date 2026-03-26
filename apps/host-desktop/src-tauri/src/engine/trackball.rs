//! Trackball inertia physics.
//!
//! When a FLING gesture is received, the trackball enters inertia mode:
//! the cursor continues to move with the given velocity, decelerating
//! each frame by a friction coefficient until speed drops below threshold.

/// Trackball physics state.
#[derive(Debug, Clone)]
pub struct TrackballState {
    /// Current velocity [vx, vy] in screen pixels per frame.
    pub vx: f64,
    pub vy: f64,
    /// Friction coefficient (0.85–0.99). Applied each frame: v *= friction.
    pub friction: f64,
    /// Stop threshold: when |v| < stop_threshold, velocity is zeroed.
    pub stop_threshold: f64,
    /// Whether the trackball is currently in inertia (coasting) mode.
    pub coasting: bool,
}

impl Default for TrackballState {
    fn default() -> Self {
        Self {
            vx: 0.0,
            vy: 0.0,
            friction: 0.92,
            stop_threshold: 0.5,
            coasting: false,
        }
    }
}

impl TrackballState {
    pub fn new(friction: f64, stop_threshold: f64) -> Self {
        Self {
            friction,
            stop_threshold,
            ..Default::default()
        }
    }

    /// Start a fling with the given velocity (screen pixels/frame).
    pub fn fling(&mut self, vx: f64, vy: f64) {
        self.vx = vx;
        self.vy = vy;
        self.coasting = true;
    }

    /// Advance physics by one frame (16ms).
    ///
    /// Returns the cursor delta to apply this frame, or (0, 0) if stopped.
    pub fn tick(&mut self) -> (f64, f64) {
        if !self.coasting {
            return (0.0, 0.0);
        }

        let dx = self.vx;
        let dy = self.vy;

        self.vx *= self.friction;
        self.vy *= self.friction;

        let speed = (self.vx * self.vx + self.vy * self.vy).sqrt();
        if speed < self.stop_threshold {
            self.vx = 0.0;
            self.vy = 0.0;
            self.coasting = false;
        }

        (dx, dy)
    }

    /// Stop inertia immediately (e.g., user touches screen again).
    pub fn stop(&mut self) {
        self.vx = 0.0;
        self.vy = 0.0;
        self.coasting = false;
    }

    /// Remaining speed magnitude.
    pub fn speed(&self) -> f64 {
        (self.vx * self.vx + self.vy * self.vy).sqrt()
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fling_decays_to_stop() {
        let mut state = TrackballState::new(0.92, 0.5);
        state.fling(50.0, 0.0);

        let mut frames = 0;
        while state.coasting {
            state.tick();
            frames += 1;
            assert!(frames < 1000, "should stop within 1000 frames");
        }
        assert!(!state.coasting);
        assert!(state.speed() < 0.5);
    }

    #[test]
    fn higher_friction_stops_faster() {
        let mut slow = TrackballState::new(0.92, 0.5);
        let mut fast = TrackballState::new(0.70, 0.5);

        slow.fling(100.0, 0.0);
        fast.fling(100.0, 0.0);

        let mut slow_frames = 0;
        while slow.coasting {
            slow.tick();
            slow_frames += 1;
        }

        let mut fast_frames = 0;
        while fast.coasting {
            fast.tick();
            fast_frames += 1;
        }

        assert!(
            fast_frames < slow_frames,
            "higher friction (0.70) should stop faster"
        );
    }

    #[test]
    fn stop_immediately_halts() {
        let mut state = TrackballState::default();
        state.fling(100.0, 100.0);
        state.stop();
        assert!(!state.coasting);
        assert_eq!(state.tick(), (0.0, 0.0));
    }

    #[test]
    fn no_coast_when_not_flinging() {
        let mut state = TrackballState::default();
        assert_eq!(state.tick(), (0.0, 0.0));
        assert!(!state.coasting);
    }

    #[test]
    fn total_travel_reasonable() {
        let mut state = TrackballState::new(0.92, 0.5);
        state.fling(20.0, 0.0);

        let mut total_x = 0.0;
        while state.coasting {
            let (dx, _) = state.tick();
            total_x += dx;
        }
        // With v0=20 and friction=0.92, total ~= v0 / (1 - 0.92) = 250 px
        assert!(
            total_x > 100.0 && total_x < 500.0,
            "total travel: {}",
            total_x
        );
    }
}
