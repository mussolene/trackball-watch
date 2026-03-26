//! 2D Kalman filter for touch input smoothing.
//!
//! State vector: [x, y, vx, vy]
//! Observation: [x, y]
//!
//! Tuning parameters (defaults):
//! - Q_pos = 0.1  (process noise for position)
//! - Q_vel = 1.0  (process noise for velocity)
//! - R     = 0.5  (measurement noise)

/// 2×2 matrix, row-major.
#[derive(Debug, Clone, Copy)]
struct Mat2 {
    m: [[f64; 2]; 2],
}

impl Mat2 {
    fn zero() -> Self {
        Self { m: [[0.0; 2]; 2] }
    }

    fn identity() -> Self {
        Self { m: [[1.0, 0.0], [0.0, 1.0]] }
    }

    fn add(self, rhs: Self) -> Self {
        Self {
            m: [
                [self.m[0][0] + rhs.m[0][0], self.m[0][1] + rhs.m[0][1]],
                [self.m[1][0] + rhs.m[1][0], self.m[1][1] + rhs.m[1][1]],
            ],
        }
    }

    fn mul(self, rhs: Self) -> Self {
        let a = self.m;
        let b = rhs.m;
        Self {
            m: [
                [
                    a[0][0] * b[0][0] + a[0][1] * b[1][0],
                    a[0][0] * b[0][1] + a[0][1] * b[1][1],
                ],
                [
                    a[1][0] * b[0][0] + a[1][1] * b[1][0],
                    a[1][0] * b[0][1] + a[1][1] * b[1][1],
                ],
            ],
        }
    }

    fn transpose(self) -> Self {
        Self {
            m: [[self.m[0][0], self.m[1][0]], [self.m[0][1], self.m[1][1]]],
        }
    }

    /// Invert a 2×2 matrix. Returns None if singular.
    fn inverse(self) -> Option<Self> {
        let [[a, b], [c, d]] = self.m;
        let det = a * d - b * c;
        if det.abs() < 1e-12 {
            return None;
        }
        Some(Self {
            m: [[d / det, -b / det], [-c / det, a / det]],
        })
    }

    fn scale(self, s: f64) -> Self {
        Self {
            m: [
                [self.m[0][0] * s, self.m[0][1] * s],
                [self.m[1][0] * s, self.m[1][1] * s],
            ],
        }
    }
}

/// 4×4 matrix, row-major (for the full state covariance).
#[derive(Debug, Clone, Copy)]
struct Mat4 {
    m: [[f64; 4]; 4],
}

impl Mat4 {
    fn zero() -> Self {
        Self { m: [[0.0; 4]; 4] }
    }

    fn identity() -> Self {
        let mut r = Self::zero();
        for i in 0..4 {
            r.m[i][i] = 1.0;
        }
        r
    }

    fn add(self, rhs: Self) -> Self {
        let mut r = Self::zero();
        for i in 0..4 {
            for j in 0..4 {
                r.m[i][j] = self.m[i][j] + rhs.m[i][j];
            }
        }
        r
    }

    fn sub(self, rhs: Self) -> Self {
        let mut r = Self::zero();
        for i in 0..4 {
            for j in 0..4 {
                r.m[i][j] = self.m[i][j] - rhs.m[i][j];
            }
        }
        r
    }

    fn mul(self, rhs: Self) -> Self {
        let mut r = Self::zero();
        for i in 0..4 {
            for j in 0..4 {
                for k in 0..4 {
                    r.m[i][j] += self.m[i][k] * rhs.m[k][j];
                }
            }
        }
        r
    }

    fn transpose(self) -> Self {
        let mut r = Self::zero();
        for i in 0..4 {
            for j in 0..4 {
                r.m[i][j] = self.m[j][i];
            }
        }
        r
    }

    /// Extract the 2×2 top-left block (observation submatrix H * P * H^T).
    fn top_left_2x2(self) -> Mat2 {
        Mat2 {
            m: [
                [self.m[0][0], self.m[0][1]],
                [self.m[1][0], self.m[1][1]],
            ],
        }
    }
}

/// Multiply Mat4 by a 4-vector.
fn mat4_vec4(m: &Mat4, v: [f64; 4]) -> [f64; 4] {
    let mut r = [0.0f64; 4];
    for i in 0..4 {
        for j in 0..4 {
            r[i] += m.m[i][j] * v[j];
        }
    }
    r
}

/// Multiply 4×2 matrix (K) by a 2-vector (innovation).
fn mat42_vec2(k: &[[f64; 2]; 4], v: [f64; 2]) -> [f64; 4] {
    let mut r = [0.0f64; 4];
    for i in 0..4 {
        r[i] = k[i][0] * v[0] + k[i][1] * v[1];
    }
    r
}

// ── Kalman2D ──────────────────────────────────────────────────────────────────

/// Configuration for the 2D Kalman filter.
#[derive(Debug, Clone, Copy)]
pub struct KalmanConfig {
    /// Process noise for position (larger = more responsive, less smooth).
    pub q_pos: f64,
    /// Process noise for velocity.
    pub q_vel: f64,
    /// Measurement noise (larger = smoother but more lag).
    pub r_noise: f64,
}

impl Default for KalmanConfig {
    fn default() -> Self {
        Self {
            q_pos: 0.1,
            q_vel: 1.0,
            r_noise: 0.5,
        }
    }
}

/// 2D Kalman filter.
///
/// State: [x, y, vx, vy]
/// Observation: [x, y]
///
/// The filter smooths noisy touch coordinates while estimating velocity
/// for fling/inertia use.
#[derive(Debug, Clone)]
pub struct Kalman2D {
    cfg: KalmanConfig,
    /// State estimate [x, y, vx, vy].
    state: [f64; 4],
    /// State covariance 4×4.
    p: Mat4,
    /// State transition matrix F (constant velocity model).
    f: Mat4,
    /// Observation matrix H (2×4): maps state to observation.
    h: [[f64; 4]; 2],
    /// Process noise Q (4×4).
    q: Mat4,
    /// Measurement noise R (2×2).
    r: Mat2,
    initialized: bool,
}

impl Kalman2D {
    pub fn new(cfg: KalmanConfig) -> Self {
        // F = I + dt * A, with dt=1 frame
        // [1 0 1 0]
        // [0 1 0 1]
        // [0 0 1 0]
        // [0 0 0 1]
        let mut f = Mat4::identity();
        f.m[0][2] = 1.0; // x += vx
        f.m[1][3] = 1.0; // y += vy

        // H = [[1,0,0,0],[0,1,0,0]]
        let h = [[1.0, 0.0, 0.0, 0.0], [0.0, 1.0, 0.0, 0.0]];

        // Q = diag(q_pos, q_pos, q_vel, q_vel)
        let mut q = Mat4::zero();
        q.m[0][0] = cfg.q_pos;
        q.m[1][1] = cfg.q_pos;
        q.m[2][2] = cfg.q_vel;
        q.m[3][3] = cfg.q_vel;

        // R = diag(r_noise, r_noise)
        let r = Mat2 {
            m: [[cfg.r_noise, 0.0], [0.0, cfg.r_noise]],
        };

        Self {
            cfg,
            state: [0.0; 4],
            p: Mat4::identity().mul(Mat4 {
                m: {
                    let mut m = [[0.0f64; 4]; 4];
                    for i in 0..4 {
                        m[i][i] = 1000.0; // high initial uncertainty
                    }
                    m
                },
            }),
            f,
            h,
            q,
            r,
            initialized: false,
        }
    }

    /// Update the filter with a new observation [x, y].
    /// Returns the filtered [x, y, vx, vy].
    pub fn update(&mut self, x: f64, y: f64) -> [f64; 4] {
        if !self.initialized {
            self.state = [x, y, 0.0, 0.0];
            self.initialized = true;
            return self.state;
        }

        // ── Predict ───────────────────────────────────────────────────────────
        let x_pred = mat4_vec4(&self.f, self.state);
        let p_pred = self.f.mul(self.p).mul(self.f.transpose()).add(self.q);

        // ── Update ────────────────────────────────────────────────────────────
        // Innovation: z - H * x_pred
        let hx = [
            self.h[0][0] * x_pred[0] + self.h[0][2] * x_pred[2],
            self.h[1][1] * x_pred[1] + self.h[1][3] * x_pred[3],
        ];
        let innovation = [x - hx[0], y - hx[1]];

        // S = H * P_pred * H^T + R
        // Since H selects rows 0 and 1, H*P*H^T is the top-left 2×2 of P_pred.
        let hp_ht = p_pred.top_left_2x2();
        let s = hp_ht.add(self.r);

        let s_inv = match s.inverse() {
            Some(inv) => inv,
            None => {
                self.state = x_pred;
                self.p = p_pred;
                return self.state;
            }
        };

        // K = P_pred * H^T * S^-1  (4×2 matrix)
        // P_pred * H^T: since H^T selects columns 0 and 1, this is
        // the first 2 columns of P_pred.
        let mut k = [[0.0f64; 2]; 4];
        for i in 0..4 {
            // P_pred * H^T column 0 = P_pred[:, 0]
            // P_pred * H^T column 1 = P_pred[:, 1]
            let ph0 = p_pred.m[i][0];
            let ph1 = p_pred.m[i][1];
            k[i][0] = ph0 * s_inv.m[0][0] + ph1 * s_inv.m[1][0];
            k[i][1] = ph0 * s_inv.m[0][1] + ph1 * s_inv.m[1][1];
        }

        // x_new = x_pred + K * innovation
        let k_inn = mat42_vec2(&k, innovation);
        let mut new_state = [0.0f64; 4];
        for i in 0..4 {
            new_state[i] = x_pred[i] + k_inn[i];
        }

        // P_new = (I - K*H) * P_pred
        // K*H is 4×4: (K*H)[i][j] = K[i][0]*H[0][j] + K[i][1]*H[1][j]
        let mut kh = Mat4::zero();
        for i in 0..4 {
            for j in 0..4 {
                kh.m[i][j] = k[i][0] * self.h[0][j] + k[i][1] * self.h[1][j];
            }
        }
        let i_kh = Mat4::identity().sub(kh);
        let new_p = i_kh.mul(p_pred);

        self.state = new_state;
        self.p = new_p;
        self.state
    }

    /// Estimated velocity [vx, vy].
    pub fn velocity(&self) -> (f64, f64) {
        (self.state[2], self.state[3])
    }

    /// Reset the filter to uninitialized state.
    pub fn reset(&mut self) {
        self.initialized = false;
        self.state = [0.0; 4];
        for i in 0..4 {
            for j in 0..4 {
                self.p.m[i][j] = if i == j { 1000.0 } else { 0.0 };
            }
        }
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn converges_on_constant_signal() {
        let mut kf = Kalman2D::new(KalmanConfig::default());
        // Feed a constant signal — filter should converge close to it.
        for _ in 0..50 {
            kf.update(100.0, 200.0);
        }
        let s = kf.state;
        assert!((s[0] - 100.0).abs() < 0.5, "x should converge: {}", s[0]);
        assert!((s[1] - 200.0).abs() < 0.5, "y should converge: {}", s[1]);
    }

    #[test]
    fn reduces_noise_variance() {
        let mut kf = Kalman2D::new(KalmanConfig::default());
        // Noisy signal around (50, 50) with amplitude 5.
        let noisy: Vec<(f64, f64)> = (0..100)
            .map(|i| {
                let noise = ((i as f64 * 1.7).sin() * 5.0, (i as f64 * 2.3).cos() * 5.0);
                (50.0 + noise.0, 50.0 + noise.1)
            })
            .collect();

        // Input variance
        let n = noisy.len() as f64;
        let mean_x = noisy.iter().map(|p| p.0).sum::<f64>() / n;
        let in_var = noisy.iter().map(|p| (p.0 - mean_x).powi(2)).sum::<f64>() / n;

        let mut outputs = vec![];
        for (x, y) in &noisy {
            let s = kf.update(*x, *y);
            outputs.push(s[0]);
        }

        let out_mean = outputs.iter().sum::<f64>() / n;
        let out_var = outputs.iter().map(|v| (v - out_mean).powi(2)).sum::<f64>() / n;

        assert!(out_var < in_var, "filter should reduce variance: {} < {}", out_var, in_var);
    }

    #[test]
    fn velocity_estimate_reasonable() {
        let mut kf = Kalman2D::new(KalmanConfig::default());
        // Linear motion: x increases by 5 per step
        for i in 0..30 {
            kf.update(i as f64 * 5.0, 0.0);
        }
        let (vx, _vy) = kf.velocity();
        assert!(vx > 3.0 && vx < 7.0, "vx should be ~5: {}", vx);
    }

    #[test]
    fn reset_clears_state() {
        let mut kf = Kalman2D::new(KalmanConfig::default());
        kf.update(100.0, 200.0);
        kf.reset();
        let s = kf.update(0.0, 0.0);
        assert_eq!(s[0], 0.0);
        assert_eq!(s[1], 0.0);
    }
}
