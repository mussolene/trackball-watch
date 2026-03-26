//! Named sensitivity profiles.

use serde::{Deserialize, Serialize};

use crate::engine::accel::{AccelConfig, CurveType};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Profile {
    pub name: String,
    pub accel: AccelConfig,
    pub trackball_friction: f64,
}

impl Profile {
    pub fn builtin_profiles() -> Vec<Self> {
        vec![
            Profile {
                name: "Precise".to_string(),
                accel: AccelConfig {
                    curve: CurveType::SCurve,
                    sensitivity: 0.6,
                    knee_point: 8.0,
                    max_delta: 25.0,
                },
                trackball_friction: 0.95,
            },
            Profile {
                name: "Default".to_string(),
                accel: AccelConfig::default(),
                trackball_friction: 0.92,
            },
            Profile {
                name: "Fast".to_string(),
                accel: AccelConfig {
                    curve: CurveType::SCurve,
                    sensitivity: 1.8,
                    knee_point: 3.5,
                    max_delta: 60.0,
                },
                trackball_friction: 0.88,
            },
            Profile {
                name: "Linear".to_string(),
                accel: AccelConfig {
                    curve: CurveType::Linear,
                    sensitivity: 1.0,
                    knee_point: 5.0,
                    max_delta: 40.0,
                },
                trackball_friction: 0.90,
            },
        ]
    }
}
