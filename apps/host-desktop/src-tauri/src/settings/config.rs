//! Application configuration persistence.

use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;

use crate::engine::accel::AccelConfig;

/// Full application settings.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct AppConfig {
    pub sensitivity: f64,
    pub mode: InputMode,
    pub hand: Hand,
    pub accel: AccelConfig,
    pub kalman_q_pos: f64,
    pub kalman_q_vel: f64,
    pub kalman_r_noise: f64,
    pub trackball_friction: f64,
    pub udp_port: u16,
    pub device_id: String,
    pub start_minimized: bool,
    pub start_on_login: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum InputMode {
    #[default]
    Trackpad,
    Trackball,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum Hand {
    #[default]
    Right,
    Left,
}

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            sensitivity: 1.0,
            mode: InputMode::Trackpad,
            hand: Hand::Right,
            accel: AccelConfig::default(),
            kalman_q_pos: 0.1,
            kalman_q_vel: 1.0,
            kalman_r_noise: 0.5,
            trackball_friction: 0.92,
            udp_port: 47474,
            device_id: String::new(),
            start_minimized: true,
            start_on_login: false,
        }
    }
}

impl AppConfig {
    pub fn load() -> Self {
        let mut cfg = match config_path() {
            Some(path) if path.exists() => {
                let data = fs::read_to_string(&path).unwrap_or_default();
                serde_json::from_str(&data).unwrap_or_default()
            }
            _ => Self::default(),
        };

        if cfg.device_id.is_empty() {
            cfg.device_id = generate_device_id();
            let _ = cfg.save();
        }
        cfg
    }

    pub fn save(&self) -> anyhow::Result<()> {
        let path = config_path().ok_or_else(|| anyhow::anyhow!("no config dir"))?;
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let json = serde_json::to_string_pretty(self)?;
        fs::write(path, json)?;
        Ok(())
    }
}

fn generate_device_id() -> String {
    use rand::RngCore;

    let mut bytes = [0u8; 16];
    rand::thread_rng().fill_bytes(&mut bytes);
    bytes.iter().map(|b| format!("{:02x}", b)).collect()
}

fn config_path() -> Option<PathBuf> {
    dirs::config_dir().map(|d| d.join("TrackBallWatch").join("config.json"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_config_serializes() {
        let cfg = AppConfig::default();
        let json = serde_json::to_string(&cfg).unwrap();
        let back: AppConfig = serde_json::from_str(&json).unwrap();
        assert_eq!(back.udp_port, 47474);
        assert_eq!(back.sensitivity, 1.0);
    }

    #[test]
    fn unknown_fields_ignored_on_load() {
        let json = r#"{"sensitivity":2.0,"unknown_field":true}"#;
        let cfg: AppConfig = serde_json::from_str(json).unwrap();
        assert_eq!(cfg.sensitivity, 2.0);
    }
}
