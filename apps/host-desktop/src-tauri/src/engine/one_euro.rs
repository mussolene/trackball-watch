//! One-Euro filter for real-time signal smoothing.
//!
//! Adapts its cutoff frequency based on the signal's derivative:
//! - At low speed (small derivative): low cutoff → heavy smoothing (less jitter)
//! - At high speed (large derivative): high cutoff → light smoothing (less lag)
//!
//! Reference: Géry Casiez, Nicolas Roussel, Daniel Vogel (2012).
//! "1 € Filter: A Simple Speed-based Low-pass Filter for Noisy Input in Interactive Systems"

use std::f64::consts::TAU;

pub struct OneEuroFilter {
    freq: f64,
    min_cutoff: f64,
    beta: f64,
    d_cutoff: f64,
    x_prev: Option<f64>,
    dx_prev: f64,
}

impl OneEuroFilter {
    /// Create a new filter.
    ///
    /// - `freq`: input frequency in Hz (e.g. 60.0)
    /// - `min_cutoff`: minimum cutoff frequency Hz (e.g. 1.0) — controls smoothing at rest
    /// - `beta`: speed coefficient — higher = less lag during fast motion (e.g. 0.007)
    /// - `d_cutoff`: cutoff for the derivative low-pass (e.g. 1.0)
    pub fn new(freq: f64, min_cutoff: f64, beta: f64, d_cutoff: f64) -> Self {
        Self {
            freq,
            min_cutoff,
            beta,
            d_cutoff,
            x_prev: None,
            dx_prev: 0.0,
        }
    }

    fn alpha(cutoff: f64, freq: f64) -> f64 {
        let tau = 1.0 / (TAU * cutoff);
        1.0 / (1.0 + tau * freq)
    }

    /// Filter a new sample, returning the smoothed value.
    /// Uses the nominal `freq` set at construction.
    pub fn filter(&mut self, x: f64) -> f64 {
        self.filter_freq(x, self.freq)
    }

    /// Filter with actual inter-sample frequency (1/dt).
    /// Use this when packet arrival rate is variable to avoid filter mis-tuning.
    pub fn filter_dt(&mut self, x: f64, dt: f64) -> f64 {
        let freq = (1.0 / dt).clamp(10.0, 200.0);
        self.filter_freq(x, freq)
    }

    fn filter_freq(&mut self, x: f64, freq: f64) -> f64 {
        let Some(x_prev) = self.x_prev else {
            self.x_prev = Some(x);
            return x;
        };

        // Derivative estimate (filtered)
        let dx_raw = (x - x_prev) * freq;
        let a_d = Self::alpha(self.d_cutoff, freq);
        let dx_hat = self.dx_prev + a_d * (dx_raw - self.dx_prev);

        // Adaptive cutoff based on speed
        let cutoff = self.min_cutoff + self.beta * dx_hat.abs();
        let a = Self::alpha(cutoff, freq);

        let x_hat = x_prev + a * (x - x_prev);

        self.x_prev = Some(x_hat);
        self.dx_prev = dx_hat;
        x_hat
    }

    pub fn reset(&mut self) {
        self.x_prev = None;
        self.dx_prev = 0.0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn passes_constant_signal() {
        let mut f = OneEuroFilter::new(60.0, 1.0, 0.007, 1.0);
        for _ in 0..100 {
            let out = f.filter(5.0);
            // After convergence the output should be close to input
            let _ = out;
        }
        let out = f.filter(5.0);
        assert!((out - 5.0).abs() < 0.01, "converged output: {}", out);
    }

    #[test]
    fn first_sample_returned_as_is() {
        let mut f = OneEuroFilter::new(60.0, 1.0, 0.007, 1.0);
        assert_eq!(f.filter(42.0), 42.0);
    }

    #[test]
    fn reset_clears_state() {
        let mut f = OneEuroFilter::new(60.0, 1.0, 0.007, 1.0);
        f.filter(100.0);
        f.reset();
        assert_eq!(f.filter(0.0), 0.0);
    }
}
