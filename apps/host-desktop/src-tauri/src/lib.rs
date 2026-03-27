pub mod engine;
pub mod injector;
pub mod protocol;
pub mod server;
pub mod settings;

use sha2::{Digest, Sha256};
use std::sync::{Arc, Mutex};
use tauri::{
    menu::{Menu, MenuItem},
    tray::TrayIconBuilder,
    Emitter,
    Manager,
};

use engine::kalman::{Kalman2D, KalmanConfig};
use engine::trackball::TrackballState;
use protocol::packets::{GestureType, TouchPhase};
use server::udp::{InputEvent, UdpServer};
use settings::config::{AppConfig, InputMode};

/// Shared application state (input pipeline + connection info).
struct AppState {
    config: AppConfig,
    kalman: Kalman2D,
    trackball: TrackballState,
    last_touch_x: f64,
    last_touch_y: f64,
    connected_peer: Option<ConnectedPeer>,
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
            connected_peer: None,
        }
    }
}

#[derive(serde::Serialize, serde::Deserialize, Clone)]
struct ConnectedPeer {
    addr: String,
}

#[derive(serde::Serialize, Clone)]
struct ConnectionStatusPayload {
    state: String,
    peer: Option<ConnectedPeer>,
}

// ── Tauri commands ────────────────────────────────────────────────────────────

#[tauri::command]
fn get_config(state: tauri::State<Arc<Mutex<AppState>>>) -> AppConfig {
    state.lock().unwrap().config.clone()
}

#[tauri::command]
fn save_config(config: AppConfig, state: tauri::State<Arc<Mutex<AppState>>>) -> Result<(), String> {
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
fn get_connection_status(state: tauri::State<Arc<Mutex<AppState>>>) -> ConnectionStatusPayload {
    let s = state.lock().unwrap();
    match &s.connected_peer {
        Some(peer) => ConnectionStatusPayload {
            state: "connected".into(),
            peer: Some(peer.clone()),
        },
        None => ConnectionStatusPayload {
            state: "disconnected".into(),
            peer: None,
        },
    }
}

#[tauri::command]
fn disconnect_device(
    state: tauri::State<Arc<Mutex<AppState>>>,
    app: tauri::AppHandle,
) -> Result<(), String> {
    state.lock().unwrap().connected_peer = None;
    let payload = ConnectionStatusPayload {
        state: "disconnected".into(),
        peer: None,
    };
    let _ = app.emit("connection_status_changed", payload);
    update_tray(&app, false, None);
    Ok(())
}

#[tauri::command]
fn get_profiles() -> Vec<settings::profiles::Profile> {
    settings::profiles::Profile::builtin_profiles()
}

#[derive(serde::Serialize)]
struct PairingInfo {
    pairing_url: String,
    host: String,
    port: u16,
    device_id: String,
    pin: String,
}

#[tauri::command]
fn get_pairing_info(state: tauri::State<Arc<Mutex<AppState>>>) -> PairingInfo {
    let s = state.lock().unwrap();
    let host = local_ip_address().unwrap_or_else(|| "127.0.0.1".to_string());
    let port = s.config.udp_port;
    let device_id = s.config.device_id.clone();
    let pairing_url = format!("tbp://pair?host={host}&port={port}&id={device_id}");
    PairingInfo {
        pairing_url,
        pin: pairing_pin(&host, port),
        host,
        port,
        device_id,
    }
}

// ── Entry point ───────────────────────────────────────────────────────────────

pub fn run() {
    env_logger::init();

    let config = AppConfig::load();
    let udp_port = config.udp_port;
    let device_id = config.device_id.clone();
    let app_state = Arc::new(Mutex::new(AppState::new(config)));
    let app_state_udp = app_state.clone();

    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .manage(app_state)
        .invoke_handler(tauri::generate_handler![
            get_config,
            save_config,
            get_connection_status,
            disconnect_device,
            get_profiles,
            get_pairing_info,
        ])
        .setup(move |app| {
            let app_handle = app.handle().clone();

            // ── Tray ──────────────────────────────────────────────────────────
            let quit =
                MenuItem::with_id(app, "quit", "Quit TrackBall Watch", true, None::<&str>)?;
            let settings_item =
                MenuItem::with_id(app, "settings", "Settings…", true, None::<&str>)?;
            let show_qr_item =
                MenuItem::with_id(app, "show_qr", "Show Pairing QR…", true, None::<&str>)?;
            let disconnect_item =
                MenuItem::with_id(app, "disconnect", "Disconnect Device", true, None::<&str>)?;
            let menu = Menu::with_items(
                app,
                &[&show_qr_item, &settings_item, &disconnect_item, &quit],
            )?;

            TrayIconBuilder::with_id("main-tray")
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
                    "show_qr" => {
                        if let Some(win) = app.get_webview_window("main") {
                            let _ = win.show();
                            let _ = win.set_focus();
                        }
                        let _ = app.emit("open_pairing_tab", ());
                    }
                    "disconnect" => {
                        if let Some(state) = app.try_state::<Arc<Mutex<AppState>>>() {
                            state.lock().unwrap().connected_peer = None;
                        }
                        let payload = ConnectionStatusPayload {
                            state: "disconnected".into(),
                            peer: None,
                        };
                        let _ = app.emit("connection_status_changed", payload);
                        update_tray(app, false, None);
                    }
                    _ => {}
                })
                .build(app)?;

            // ── UDP server ────────────────────────────────────────────────────
            let state_for_thread = app_state_udp;
            let handle_for_thread = app_handle;

            std::thread::spawn(move || {
                let rt = tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                    .expect("tokio runtime");
                rt.block_on(async move {
                    let _mdns = if let Ok(mut mdns) = server::mdns::MdnsAdvertiser::new() {
                        let _ = mdns.advertise(udp_port, &device_id);
                        Some(mdns)
                    } else {
                        None
                    };
                    let mut server = UdpServer::new(udp_port);
                    server.on_event(Arc::new(move |event| {
                        handle_input_event(event, &state_for_thread, &handle_for_thread);
                    }));
                    if let Err(e) = server.run().await {
                        log::error!("UDP server: {}", e);
                    }
                });
            });

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error running tauri application");
}

// ── Helpers ───────────────────────────────────────────────────────────────────

fn update_tray(app: &tauri::AppHandle, connected: bool, peer_addr: Option<&str>) {
    if let Some(tray) = app.tray_by_id("main-tray") {
        let tooltip = if connected {
            format!(
                "TrackBall Watch — Connected{}",
                peer_addr
                    .map(|a| format!(" ({})", a))
                    .unwrap_or_default()
            )
        } else {
            "TrackBall Watch — Disconnected".to_string()
        };
        let _ = tray.set_tooltip(Some(tooltip));
    }
}

fn local_ip_address() -> Option<String> {
    // Try each RFC-1918 LAN subnet to find the real LAN interface.
    // This avoids returning the VPN tunnel IP (e.g. 198.18.x.x) which
    // the iPhone can't reach directly.
    for target in &["192.168.1.1:80", "10.0.0.1:80", "172.16.0.1:80"] {
        let socket = std::net::UdpSocket::bind("0.0.0.0:0").ok()?;
        if socket.connect(target).is_ok() {
            if let Ok(addr) = socket.local_addr() {
                let ip = addr.ip().to_string();
                // Skip loopback and link-local addresses
                if !ip.starts_with("127.") && !ip.starts_with("169.254.") {
                    return Some(ip);
                }
            }
        }
    }
    // Fallback: default route (may be VPN)
    let socket = std::net::UdpSocket::bind("0.0.0.0:0").ok()?;
    socket.connect("8.8.8.8:80").ok()?;
    let addr = socket.local_addr().ok()?;
    Some(addr.ip().to_string())
}

fn pairing_pin(host: &str, port: u16) -> String {
    let window = (std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
        / 300) as i64;
    let raw = format!("{host}:{port}-{window}");
    let digest = Sha256::digest(raw.as_bytes());
    let value = u32::from_le_bytes([digest[0], digest[1], digest[2], digest[3]]);
    format!("{:06}", value % 1_000_000)
}

// ── Input event handler ───────────────────────────────────────────────────────

fn handle_input_event(
    event: InputEvent,
    state: &Arc<Mutex<AppState>>,
    app: &tauri::AppHandle,
) {
    match event {
        InputEvent::Connected { peer_addr } => {
            log::info!("Device connected: {}", peer_addr);
            let peer = ConnectedPeer {
                addr: peer_addr.to_string(),
            };
            state.lock().unwrap().connected_peer = Some(peer.clone());

            let payload = ConnectionStatusPayload {
                state: "connected".into(),
                peer: Some(peer),
            };
            let _ = app.emit("connection_status_changed", payload);
            update_tray(app, true, Some(&peer_addr.to_string()));

            // Bring window to front when a device connects
            if let Some(win) = app.get_webview_window("main") {
                let _ = win.show();
                let _ = win.set_focus();
            }
        }

        InputEvent::Disconnected => {
            log::info!("Device disconnected");
            {
                let mut s = state.lock().unwrap();
                s.connected_peer = None;
                s.kalman.reset();
                s.trackball.stop();
            }
            let payload = ConnectionStatusPayload {
                state: "disconnected".into(),
                peer: None,
            };
            let _ = app.emit("connection_status_changed", payload);
            update_tray(app, false, None);
        }

        InputEvent::Heartbeat(_) => {}

        InputEvent::Touch(_, payload) => {
            let injector = match injector::create_injector() {
                Ok(i) => i,
                Err(e) => {
                    log::warn!("Injector unavailable: {}", e);
                    return;
                }
            };
            let mut s = state.lock().unwrap();
            let phase = TouchPhase::try_from(payload.phase).unwrap_or(TouchPhase::Moved);

            if matches!(phase, TouchPhase::Ended | TouchPhase::Cancelled) {
                s.kalman.reset();
                s.trackball.stop();
                return;
            }

            let filtered = s.kalman.update(payload.x as f64, payload.y as f64);
            let dx = filtered[0] - s.last_touch_x;
            let dy = filtered[1] - s.last_touch_y;
            s.last_touch_x = filtered[0];
            s.last_touch_y = filtered[1];

            if phase == TouchPhase::Began {
                return;
            }

            let cfg = s.config.accel;
            drop(s);
            let (sx, sy) = engine::accel::apply_curve_2d(dx, dy, &cfg);
            let _ = injector.move_relative(sx, sy);
        }

        InputEvent::Gesture(_, payload) => {
            let injector = match injector::create_injector() {
                Ok(i) => i,
                Err(e) => {
                    log::warn!("Injector unavailable: {}", e);
                    return;
                }
            };
            let mut s = state.lock().unwrap();
            match GestureType::try_from(payload.gesture_type).ok() {
                Some(GestureType::Tap) => {
                    drop(s);
                    let _ = injector.left_click();
                }
                Some(GestureType::DoubleTap) => {
                    drop(s);
                    let _ = injector.left_click();
                    let _ = injector.left_click();
                }
                Some(GestureType::LongPress) => {
                    drop(s);
                    let _ = injector.right_click();
                }
                Some(GestureType::Fling) if s.config.mode == InputMode::Trackball => {
                    s.trackball
                        .fling(payload.param1 as f64, payload.param2 as f64);
                }
                _ => {}
            }
        }

        InputEvent::Crown(_, payload) => {
            let injector = match injector::create_injector() {
                Ok(i) => i,
                Err(e) => {
                    log::warn!("Injector unavailable: {}", e);
                    return;
                }
            };
            let _ = injector.scroll_vertical(payload.delta as f64 / 100.0);
        }
    }
}
