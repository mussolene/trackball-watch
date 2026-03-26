pub mod engine;
pub mod injector;
pub mod protocol;
pub mod server;
pub mod settings;

use std::sync::{Arc, Mutex};
use tauri::{
    Manager,
    tray::{TrayIconBuilder, TrayIconEvent},
    menu::{Menu, MenuItem},
};

use engine::accel::AccelConfig;
use engine::kalman::{Kalman2D, KalmanConfig};
use engine::trackball::TrackballState;
use protocol::packets::{GestureType, TouchPhase, packet_type};
use server::udp::{InputEvent, UdpServer, DEFAULT_PORT};
use settings::config::{AppConfig, InputMode};

/// Shared application state.
struct AppState {
    config: AppConfig,
    kalman: Kalman2D,
    trackball: TrackballState,
    last_touch_x: f64,
    last_touch_y: f64,
}

impl AppState {
    fn new(config: AppConfig) -> Self {
        let kalman = Kalman2D::new(KalmanConfig {
            q_pos: config.kalman_q_pos,
            q_vel: config.kalman_q_vel,
            r_noise: config.kalman_r_noise,
        });
        let trackball = TrackballState::new(config.trackball_friction, 0.5);
        Self {
            config,
            kalman,
            trackball,
            last_touch_x: 0.0,
            last_touch_y: 0.0,
        }
    }
}

// ── Tauri commands (callable from Svelte UI) ──────────────────────────────────

#[tauri::command]
fn get_config(state: tauri::State<Arc<Mutex<AppState>>>) -> AppConfig {
    state.lock().unwrap().config.clone()
}

#[tauri::command]
fn save_config(
    config: AppConfig,
    state: tauri::State<Arc<Mutex<AppState>>>,
) -> Result<(), String> {
    config.save().map_err(|e| e.to_string())?;
    let mut s = state.lock().unwrap();
    s.kalman = Kalman2D::new(KalmanConfig {
        q_pos: config.kalman_q_pos,
        q_vel: config.kalman_q_vel,
        r_noise: config.kalman_r_noise,
    });
    s.trackball = TrackballState::new(config.trackball_friction, 0.5);
    s.config = config;
    Ok(())
}

#[tauri::command]
fn get_connection_status(state: tauri::State<Arc<Mutex<AppState>>>) -> String {
    // Simplified: would query ConnectionManager in real impl
    "disconnected".to_string()
}

#[tauri::command]
fn get_profiles() -> Vec<settings::profiles::Profile> {
    settings::profiles::Profile::builtin_profiles()
}

// ── Entry point ───────────────────────────────────────────────────────────────

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    env_logger::init();

    let config = AppConfig::load();
    let app_state = Arc::new(Mutex::new(AppState::new(config.clone())));
    let app_state_for_server = app_state.clone();
    let udp_port = config.udp_port;

    // Start UDP server in background
    tokio::runtime::Runtime::new()
        .expect("tokio runtime")
        .block_on(async {
            // Spawn UDP server
            let state_cb = app_state_for_server.clone();
            tokio::spawn(async move {
                let mut server = UdpServer::new(udp_port);
                server.on_event(Arc::new(move |event| {
                    handle_input_event(event, &state_cb);
                }));
                if let Err(e) = server.run().await {
                    log::error!("UDP server error: {}", e);
                }
            });

            // Build and run Tauri app
            tauri::Builder::default()
                .plugin(tauri_plugin_shell::init())
                .manage(app_state)
                .invoke_handler(tauri::generate_handler![
                    get_config,
                    save_config,
                    get_connection_status,
                    get_profiles,
                ])
                .setup(|app| {
                    // Build system tray
                    let quit = MenuItem::with_id(app, "quit", "Quit TrackBall Watch", true, None::<&str>)?;
                    let settings = MenuItem::with_id(app, "settings", "Settings…", true, None::<&str>)?;
                    let menu = Menu::with_items(app, &[&settings, &quit])?;

                    TrayIconBuilder::new()
                        .menu(&menu)
                        .tooltip("TrackBall Watch — Disconnected")
                        .on_menu_event(|app, event| match event.id.as_ref() {
                            "quit" => app.exit(0),
                            "settings" => {
                                if let Some(win) = app.get_webview_window("main") {
                                    let _ = win.show();
                                    let _ = win.set_focus();
                                }
                            }
                            _ => {}
                        })
                        .build(app)?;

                    Ok(())
                })
                .run(tauri::generate_context!())
                .expect("error running tauri");
        });
}

fn handle_input_event(event: InputEvent, state: &Arc<Mutex<AppState>>) {
    let injector = match injector::create_injector() {
        Ok(i) => i,
        Err(e) => {
            log::warn!("Injector unavailable: {}", e);
            return;
        }
    };

    let mut s = state.lock().unwrap();

    match event {
        InputEvent::Touch(_, payload) => {
            let phase = TouchPhase::try_from(payload.phase).unwrap_or(TouchPhase::Moved);

            match phase {
                TouchPhase::Ended | TouchPhase::Cancelled => {
                    s.kalman.reset();
                    s.trackball.stop();
                    return;
                }
                _ => {}
            }

            // Kalman filter
            let filtered = s.kalman.update(payload.x as f64, payload.y as f64);
            let dx = filtered[0] - s.last_touch_x;
            let dy = filtered[1] - s.last_touch_y;
            s.last_touch_x = filtered[0];
            s.last_touch_y = filtered[1];

            if phase == TouchPhase::Began {
                return; // skip first frame delta
            }

            let cfg = s.config.accel;
            let (sx, sy) = engine::accel::apply_curve_2d(dx, dy, &cfg);
            let _ = injector.move_relative(sx, sy);
        }

        InputEvent::Gesture(_, payload) => {
            let gtype = GestureType::try_from(payload.gesture_type).ok();
            match gtype {
                Some(GestureType::Tap) => {
                    let _ = injector.left_click();
                }
                Some(GestureType::DoubleTap) => {
                    let _ = injector.left_click();
                    let _ = injector.left_click();
                }
                Some(GestureType::LongPress) => {
                    let _ = injector.right_click();
                }
                Some(GestureType::Fling) => {
                    if s.config.mode == InputMode::Trackball {
                        let vx = payload.param1 as f64;
                        let vy = payload.param2 as f64;
                        s.trackball.fling(vx, vy);
                    }
                }
                _ => {}
            }
        }

        InputEvent::Crown(_, payload) => {
            let lines = payload.delta as f64 / 100.0;
            let _ = injector.scroll_vertical(lines);
        }

        InputEvent::Connected { peer_addr } => {
            log::info!("Device connected: {}", peer_addr);
        }

        InputEvent::Disconnected => {
            log::info!("Device disconnected");
            s.kalman.reset();
            s.trackball.stop();
        }

        InputEvent::Heartbeat(_) => {}
    }
}
