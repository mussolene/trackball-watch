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
    /// Whether the user currently has finger contact and is steering the ball.
    pub touch_active: bool,
    /// Friction coefficient (0.85–0.99). Applied each frame: v *= friction.
    pub friction: f64,
    /// Higher damping while finger is down. Keeps steering controllable and prevents overshoot.
    pub touch_friction: f64,
    /// Blend factor for steering velocity updates while dragging.
    pub drive_blend: f64,
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
            touch_active: false,
            friction: 0.92,
            touch_friction: 0.82,
            drive_blend: 0.45,
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
        self.touch_active = false;
        self.vx = vx;
        self.vy = vy;
        self.coasting = true;
    }

    /// Start a new finger-down steering interaction.
    pub fn begin_touch(&mut self) {
        self.touch_active = true;
        self.coasting = false;
    }

    /// Update steering from the latest drag sample.
    ///
    /// `dx`/`dy` are already transformed into screen-space deltas.
    pub fn drive(&mut self, dx: f64, dy: f64) {
        self.touch_active = true;
        self.coasting = false;
        self.vx = self.vx * (1.0 - self.drive_blend) + dx * self.drive_blend;
        self.vy = self.vy * (1.0 - self.drive_blend) + dy * self.drive_blend;
    }

    /// Finish steering and either continue coasting or stop.
    pub fn end_touch(&mut self) {
        self.touch_active = false;
        self.coasting = self.speed() >= self.stop_threshold;
        if !self.coasting {
            self.vx = 0.0;
            self.vy = 0.0;
        }
    }

    /// Advance physics by `dt` seconds.
    ///
    /// `friction` is stored as per-frame coefficient at 60 Hz (e.g. 0.92).
    /// The decay is made frame-rate-independent: `decay = friction ^ (dt * 60)`.
    ///
    /// Returns the cursor delta to apply, or (0, 0) if stopped.
    pub fn tick(&mut self, dt: f64) -> (f64, f64) {
        if !self.touch_active && !self.coasting {
            return (0.0, 0.0);
        }

        let dx = self.vx;
        let dy = self.vy;

        let decay = if self.touch_active {
            self.touch_friction.powf(dt * 60.0)
        } else {
            self.friction.powf(dt * 60.0)
        };
        self.vx *= decay;
        self.vy *= decay;

        let speed = (self.vx * self.vx + self.vy * self.vy).sqrt();
        if speed < self.stop_threshold {
            self.vx = 0.0;
            self.vy = 0.0;
            if !self.touch_active {
                self.coasting = false;
            }
        }

        (dx, dy)
    }

    /// Stop inertia immediately (e.g., user touches screen again).
    pub fn stop(&mut self) {
        self.vx = 0.0;
        self.vy = 0.0;
        self.touch_active = false;
        self.coasting = false;
    }

    /// Remaining speed magnitude.
    pub fn speed(&self) -> f64 {
        (self.vx * self.vx + self.vy * self.vy).sqrt()
    }

    pub fn is_active(&self) -> bool {
        self.touch_active || self.coasting
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
            state.tick(1.0 / 60.0);
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
            slow.tick(1.0 / 60.0);
            slow_frames += 1;
        }

        let mut fast_frames = 0;
        while fast.coasting {
            fast.tick(1.0 / 60.0);
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
        assert_eq!(state.tick(1.0 / 60.0), (0.0, 0.0));
    }

    #[test]
    fn no_coast_when_not_flinging() {
        let mut state = TrackballState::default();
        assert_eq!(state.tick(1.0 / 60.0), (0.0, 0.0));
        assert!(!state.coasting);
    }

    #[test]
    fn touch_drive_produces_motion_without_direct_cursor_path() {
        let mut state = TrackballState::default();
        state.begin_touch();
        state.drive(10.0, -4.0);

        let (dx, dy) = state.tick(1.0 / 60.0);
        assert!(dx.abs() > 0.0 || dy.abs() > 0.0);
        assert!(state.touch_active);
        assert!(!state.coasting);
    }

    #[test]
    fn touch_release_keeps_coasting_when_velocity_is_high() {
        let mut state = TrackballState::default();
        state.begin_touch();
        state.drive(25.0, 0.0);
        state.end_touch();

        assert!(state.coasting);
        let (dx, _) = state.tick(1.0 / 60.0);
        assert!(dx > 0.0);
    }

    #[test]
    fn touch_release_stops_when_velocity_is_small() {
        let mut state = TrackballState::default();
        state.begin_touch();
        state.drive(0.2, 0.0);
        state.end_touch();

        assert!(!state.coasting);
        assert_eq!(state.tick(1.0 / 60.0), (0.0, 0.0));
    }

    #[test]
    fn total_travel_reasonable() {
        let mut state = TrackballState::new(0.92, 0.5);
        state.fling(20.0, 0.0);

        let mut total_x = 0.0;
        while state.coasting {
            let (dx, _) = state.tick(1.0 / 60.0);
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
