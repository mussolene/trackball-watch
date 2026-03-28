pub mod engine;
pub mod injector;
pub mod protocol;
pub mod server;
pub mod settings;

use sha2::{Digest, Sha256};
use std::net::Ipv4Addr;
use std::sync::{Arc, Mutex};
use tauri::{
    menu::{Menu, MenuItem},
    tray::TrayIconBuilder,
    Emitter, Manager,
};

use engine::kalman::{Kalman2D, KalmanConfig};
use engine::one_euro::OneEuroFilter;
use engine::trackball::TrackballState;
use protocol::packets::{GestureType, TouchPhase};
use server::udp::{InputEvent, UdpServer};
use settings::config::{AppConfig, Hand, InputMode};

/// Shared application state (input pipeline + connection info).
struct AppState {
    config: AppConfig,
    kalman: Kalman2D,
    trackball: TrackballState,
    /// Last raw TBP coordinates (for delta-based pointer motion).
    last_raw_x: f64,
    last_raw_y: f64,
    last_touch_x: f64,
    last_touch_y: f64,
    smoothed_dx: f64,
    smoothed_dy: f64,
    /// One-Euro filters for dx/dy smoothing (replace adaptive EMA).
    one_euro_dx: OneEuroFilter,
    one_euro_dy: OneEuroFilter,
    /// Sub-pixel fractional accumulator — prevents rounding loss at low speeds.
    frac_x: f64,
    frac_y: f64,
    /// Timestamp of last TOUCH_MOVED packet — used to compute actual dt for One Euro filter.
    last_touch_time: Option<std::time::Instant>,
    /// Counter for throttling STATE_FEEDBACK packets (~10 Hz = every 6 coast frames).
    feedback_frame_count: u8,
    connected_peer: Option<ConnectedPeer>,
    /// Send raw packets to the connected peer via the UDP server socket.
    udp_tx: Option<tokio::sync::mpsc::UnboundedSender<Vec<u8>>>,
}

impl AppState {
    fn new(config: AppConfig) -> Self {
        let kalman = Kalman2D::new(KalmanConfig {
            q_pos: config.kalman_q_pos,
            q_vel: config.kalman_q_vel,
            r_noise: config.kalman_r_noise,
        });
        let trackball = TrackballState::new(config.trackball_friction, 0.5);
        let one_euro_dx = OneEuroFilter::new(
            60.0,
            config.one_euro_min_cutoff,
            config.one_euro_beta,
            1.0,
        );
        let one_euro_dy = OneEuroFilter::new(
            60.0,
            config.one_euro_min_cutoff,
            config.one_euro_beta,
            1.0,
        );
        Self {
            config,
            kalman,
            trackball,
            last_raw_x: 0.0,
            last_raw_y: 0.0,
            last_touch_x: 0.0,
            last_touch_y: 0.0,
            smoothed_dx: 0.0,
            smoothed_dy: 0.0,
            one_euro_dx,
            one_euro_dy,
            frac_x: 0.0,
            frac_y: 0.0,
            last_touch_time: None,
            feedback_frame_count: 0,
            connected_peer: None,
            udp_tx: None,
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
    let mut pending_mode_push: Option<(
        tokio::sync::mpsc::UnboundedSender<Vec<u8>>,
        InputMode,
        Hand,
        f64,
    )> = None;
    {
        let mut s = state.lock().unwrap();
        s.kalman = Kalman2D::new(KalmanConfig {
            q_pos: config.kalman_q_pos,
            q_vel: config.kalman_q_vel,
            r_noise: config.kalman_r_noise,
        });
        s.trackball = TrackballState::new(config.trackball_friction, 0.5);
        s.config = config;
        if let (Some(tx), Some(_)) = (s.udp_tx.clone(), s.connected_peer.as_ref()) {
            pending_mode_push = Some((tx, s.config.mode, s.config.hand, s.config.trackball_friction));
        }
    }
    if let Some((tx, mode, hand, friction)) = pending_mode_push {
        if let Err(e) = send_mode_packet(&tx, mode, hand, friction) {
            log::warn!("mode push after save failed: {}", e);
        }
    }
    Ok(())
}

/// Returns true if macOS Accessibility permission is granted.
#[tauri::command]
fn check_accessibility() -> bool {
    #[cfg(target_os = "macos")]
    {
        injector::macos::MacOSInjector::has_accessibility_permission()
    }
    #[cfg(not(target_os = "macos"))]
    {
        true
    }
}

/// Open System Settings → Accessibility so user can grant permission.
#[tauri::command]
fn open_accessibility_settings() {
    #[cfg(target_os = "macos")]
    {
        injector::macos::MacOSInjector::open_accessibility_settings();
    }
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

#[tauri::command]
fn push_mode(state: tauri::State<Arc<Mutex<AppState>>>) -> Result<(), String> {
    let s = state.lock().unwrap();
    if let Some(tx) = &s.udp_tx {
        send_mode_packet(tx, s.config.mode, s.config.hand, s.config.trackball_friction)?;
    }
    Ok(())
}

fn send_mode_packet(
    tx: &tokio::sync::mpsc::UnboundedSender<Vec<u8>>,
    mode: InputMode,
    hand: Hand,
    trackball_friction: f64,
) -> Result<(), String> {
    use crate::protocol::packets::{encode_header, packet_type, PacketHeader};
    let mode_byte: u8 = if mode == InputMode::Trackball { 1 } else { 0 };
    let hand_byte: u8 = if hand == Hand::Left { 1 } else { 0 };
    // Centi-units (50–99 → 0.50–0.99); matches watch visual coast damping.
    let friction_byte =
        ((trackball_friction.clamp(0.5, 0.99) * 100.0).round() as u8).clamp(50, 99);
    let header = PacketHeader {
        seq: 0,
        packet_type: packet_type::CONFIG,
        flags: 0,
        timestamp_us: std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| (d.as_micros() & 0xFFFF_FFFF) as u32)
            .unwrap_or(0),
    };
    let mut packet = encode_header(&header).map_err(|e| format!("{:?}", e))?;
    packet.push(mode_byte);
    packet.push(hand_byte);
    packet.push(friction_byte);
    tx.send(packet).map_err(|e| e.to_string())
}

/// Send STATE_FEEDBACK (0x13) packet to the watch at ~10 Hz during coasting.
/// Payload: is_coasting(u8) + vx_fp(i16 LE) + vy_fp(i16 LE) + reserved(4 bytes).
fn send_state_feedback(
    tx: &tokio::sync::mpsc::UnboundedSender<Vec<u8>>,
    is_coasting: bool,
    vx: f64,
    vy: f64,
) -> Result<(), String> {
    use crate::protocol::packets::{encode_header, packet_type, PacketHeader};
    let header = PacketHeader {
        seq: 0,
        packet_type: packet_type::STATE_FEEDBACK,
        flags: 0,
        timestamp_us: std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| (d.as_micros() & 0xFFFF_FFFF) as u32)
            .unwrap_or(0),
    };
    let mut packet = encode_header(&header).map_err(|e| format!("{:?}", e))?;
    // is_coasting byte
    packet.push(if is_coasting { 1u8 } else { 0u8 });
    // vx as fixed-point i16 (velocity × 64), little-endian
    let vx_fp = (vx * 64.0).clamp(-32767.0, 32767.0) as i16;
    let vy_fp = (vy * 64.0).clamp(-32767.0, 32767.0) as i16;
    packet.extend_from_slice(&vx_fp.to_le_bytes());
    packet.extend_from_slice(&vy_fp.to_le_bytes());
    // 4 reserved bytes
    packet.extend_from_slice(&[0u8; 4]);
    tx.send(packet).map_err(|e| e.to_string())
}

#[derive(serde::Serialize)]
struct PairingInfo {
    pairing_url: String,
    host: String,
    port: u16,
    device_id: String,
    pin: String,
    interface: String,
    hosts: Vec<PairingHost>,
}

#[derive(serde::Serialize)]
struct PairingHost {
    host: String,
    interface: String,
}

#[tauri::command]
fn get_pairing_info(state: tauri::State<Arc<Mutex<AppState>>>) -> PairingInfo {
    let s = state.lock().unwrap();
    let bindings = local_lan_bindings();
    let (host, iface) = bindings
        .first()
        .map(|b| (b.host.clone(), b.interface.clone()))
        .unwrap_or_else(|| ("127.0.0.1".to_string(), "loopback".to_string()));
    let port = s.config.udp_port;
    let device_id = s.config.device_id.clone();
    let pairing_url = format!("tbp://pair?host={host}&port={port}&id={device_id}");
    PairingInfo {
        pairing_url,
        pin: pairing_pin(&host, port),
        host,
        port,
        device_id,
        interface: iface,
        hosts: bindings
            .into_iter()
            .map(|b| PairingHost {
                host: b.host,
                interface: b.interface,
            })
            .collect(),
    }
}

// ── Entry point ───────────────────────────────────────────────────────────────

pub fn run() {
    env_logger::init();

    #[cfg(target_os = "macos")]
    {
        let exe = std::env::current_exe()
            .map(|p| p.display().to_string())
            .unwrap_or_else(|_| "(unknown path)".to_string());
        let trusted = injector::macos::MacOSInjector::has_accessibility_permission();
        log::info!(
            "macOS input injection: Accessibility trusted={} for {}",
            trusted,
            exe
        );
        if !trusted {
            log::warn!(
                "Accessibility is off for this executable — cursor/clicks will not work. \
                 System Settings → Privacy & Security → Accessibility → enable TrackBall Watch. \
                 Note: dev builds (`target/debug/trackball-watch`) and the installed `.app` are separate entries; enable both if you use both."
            );
        }
    }

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
            push_mode,
            check_accessibility,
            open_accessibility_settings,
        ])
        .setup(move |app| {
            let app_handle = app.handle().clone();

            // WebView follows OS appearance so `prefers-color-scheme` / Tauri theme match.
            if let Some(win) = app.get_webview_window("main") {
                let _ = win.set_theme(None);
            }

            // ── Tray ──────────────────────────────────────────────────────────
            let quit = MenuItem::with_id(app, "quit", "Quit TrackBall Watch", true, None::<&str>)?;
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

            let mut tray_builder = TrayIconBuilder::with_id("main-tray");
            if let Some(icon) = app.default_window_icon().cloned() {
                tray_builder = tray_builder.icon(icon);
            }
            tray_builder
                .icon_as_template(true)
                .show_menu_on_left_click(true)
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
            let state_for_coast = app_state_udp.clone();
            let state_for_thread = app_state_udp;
            let handle_for_thread = app_handle;

            let lan_bindings = local_lan_bindings();
            std::thread::spawn(move || {
                let rt = tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                    .expect("tokio runtime");
                std::thread::spawn(move || {
                    let mut last = std::time::Instant::now();
                    loop {
                        std::thread::sleep(std::time::Duration::from_millis(14));
                        let now = std::time::Instant::now();
                        let dt = now.duration_since(last).as_secs_f64().clamp(0.005, 0.05);
                        last = now;
                        trackball_coast_step(&state_for_coast, dt);
                    }
                });
                rt.block_on(async move {
                    let _mdns = if let Ok(mut mdns) = server::mdns::MdnsAdvertiser::new() {
                        let mdns_hosts: Vec<(String, String)> = lan_bindings
                            .iter()
                            .map(|b| (b.host.clone(), b.interface.clone()))
                            .collect();
                        let _ = mdns.advertise_many(udp_port, &device_id, &mdns_hosts);
                        Some(mdns)
                    } else {
                        None
                    };
                    let mut server = UdpServer::new(udp_port);
                    // Share outbound sender with AppState so push_mode can use it
                    if let Some(tx) = server.outbound_tx.clone() {
                        state_for_thread.lock().unwrap().udp_tx = Some(tx);
                    }
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
                peer_addr.map(|a| format!(" ({})", a)).unwrap_or_default()
            )
        } else {
            "TrackBall Watch — Disconnected".to_string()
        };
        let _ = tray.set_tooltip(Some(tooltip));
    }
}

#[derive(Clone)]
struct LanBinding {
    host: String,
    interface: String,
}

fn local_lan_bindings() -> Vec<LanBinding> {
    let addrs = match if_addrs::get_if_addrs() {
        Ok(v) => v,
        Err(_) => return Vec::new(),
    };
    let mut candidates: Vec<(u8, String, String)> = Vec::new();
    for iface in addrs {
        let ip = match iface.ip() {
            std::net::IpAddr::V4(v4) => v4,
            std::net::IpAddr::V6(_) => continue,
        };

        if !is_rfc1918_ipv4(ip) {
            continue;
        }
        let name = iface.name;
        let prio = interface_priority(&name);
        candidates.push((prio, ip.to_string(), name));
    }

    candidates.sort_by(|a, b| {
        let by_prio = a.0.cmp(&b.0);
        if by_prio == std::cmp::Ordering::Equal {
            a.2.cmp(&b.2)
        } else {
            by_prio
        }
    });
    candidates.dedup_by(|a, b| a.1 == b.1 && a.2 == b.2);

    candidates
        .into_iter()
        .map(|(_, ip, iface)| LanBinding {
            host: ip,
            interface: iface,
        })
        .collect()
}

fn is_rfc1918_ipv4(ip: Ipv4Addr) -> bool {
    let o = ip.octets();
    o[0] == 10 || (o[0] == 172 && (16..=31).contains(&o[1])) || (o[0] == 192 && o[1] == 168)
}

fn interface_priority(name: &str) -> u8 {
    if name.starts_with("en0") || name.starts_with("wlan") || name.starts_with("wifi") {
        0
    } else if name.starts_with("en") || name.starts_with("eth") {
        1
    } else {
        2
    }
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

/// Advance trackball inertia at ~60 Hz when coasting (FLING already set velocity).
fn trackball_coast_step(state: &Arc<Mutex<AppState>>, dt: f64) {
    let mut s = match state.lock() {
        Ok(g) => g,
        Err(_) => return,
    };
    if s.config.mode != InputMode::Trackball || !s.trackball.coasting {
        return;
    }
    let (dx, dy) = s.trackball.tick(dt);
    if dx == 0.0 && dy == 0.0 {
        // Coasting just stopped — send one final feedback so watch stops animating
        if let Some(tx) = s.udp_tx.clone() {
            drop(s);
            let _ = send_state_feedback(&tx, false, 0.0, 0.0);
        }
        return;
    }
    let user_scale = s.config.sensitivity.max(0.05);
    let cfg = s.config.accel;
    let vx = s.trackball.vx;
    let vy = s.trackball.vy;
    let is_coasting = s.trackball.coasting;
    let (sx, sy) = engine::accel::apply_curve_2d(dx * user_scale, dy * user_scale, &cfg);
    s.frac_x += sx;
    s.frac_y += sy;
    let ix = s.frac_x as i64;
    let iy = s.frac_y as i64;
    s.frac_x -= ix as f64;
    s.frac_y -= iy as f64;
    // Throttle STATE_FEEDBACK to ~10 Hz (every 6 frames at 60 Hz)
    s.feedback_frame_count = s.feedback_frame_count.wrapping_add(1);
    let should_send_feedback = s.feedback_frame_count % 6 == 0;
    let udp_tx = if should_send_feedback { s.udp_tx.clone() } else { None };
    drop(s);
    let injector = match injector::create_injector() {
        Ok(i) => i,
        Err(_) => return,
    };
    if ix != 0 || iy != 0 {
        let _ = injector.move_relative(ix as f64, iy as f64);
    }
    if let Some(tx) = udp_tx {
        let _ = send_state_feedback(&tx, is_coasting, vx, vy);
    }
}

// ── Input event handler ───────────────────────────────────────────────────────

fn handle_input_event(event: InputEvent, state: &Arc<Mutex<AppState>>, app: &tauri::AppHandle) {
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

            // Ensure watch mode reflects current desktop mode right after link-up.
            let mode_push = {
                let s = state.lock().unwrap();
                s.udp_tx
                    .clone()
                    .map(|tx| (tx, s.config.mode, s.config.hand, s.config.trackball_friction))
            };
            if let Some((tx, mode, hand, friction)) = mode_push {
                let _ = send_mode_packet(&tx, mode, hand, friction);
            }
        }

        InputEvent::Disconnected => {
            log::info!("Device disconnected");
            {
                let mut s = state.lock().unwrap();
                s.connected_peer = None;
                s.kalman.reset();
                s.trackball.stop();
                s.smoothed_dx = 0.0;
                s.smoothed_dy = 0.0;
                s.one_euro_dx.reset();
                s.one_euro_dy.reset();
                s.frac_x = 0.0;
                s.frac_y = 0.0;
                s.last_raw_x = 0.0;
                s.last_raw_y = 0.0;
                s.last_touch_time = None;
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
                // In trackball mode a FLING gesture may follow this touch-end; stopping here
                // would cancel coasting immediately. New touch began stops inertia instead.
                if s.config.mode != InputMode::Trackball {
                    s.trackball.stop();
                }
                s.smoothed_dx = 0.0;
                s.smoothed_dy = 0.0;
                s.last_raw_x = 0.0;
                s.last_raw_y = 0.0;
                return;
            }

            let x = payload.x as f64;
            let y = payload.y as f64;

            if phase == TouchPhase::Began {
                s.trackball.stop();
                let _ = s.kalman.update(x, y);
                s.last_raw_x = x;
                s.last_raw_y = y;
                s.last_touch_x = x;
                s.last_touch_y = y;
                s.smoothed_dx = 0.0;
                s.smoothed_dy = 0.0;
                s.one_euro_dx.reset();
                s.one_euro_dy.reset();
                s.frac_x = 0.0;
                s.frac_y = 0.0;
                s.last_touch_time = None;
                return;
            }

            // Raw delta between successive samples. Kalman on absolute position was crushing
            // per-frame deltas (filtered position barely moves), which made the cursor stick.
            let mut dx = x - s.last_raw_x;
            let mut dy = y - s.last_raw_y;
            s.last_raw_x = x;
            s.last_raw_y = y;
            s.last_touch_x = x;
            s.last_touch_y = y;

            // Global sensitivity slider × accel curve sensitivity (UI updates `sensitivity`).
            let user_scale = s.config.sensitivity.max(0.05);
            dx *= user_scale;
            dy *= user_scale;

            // Pressure 1–255 scales delta; 0 leaves gain off (e.g. trackpad sends no pressure).
            let p = payload.pressure;
            if p > 0 {
                let gain = 0.4 + 0.6 * (p as f64 / 255.0);
                dx *= gain;
                dy *= gain;
            }

            // Adaptive deadzone:
            // - Trackpad: heavier deadzone to suppress finger contact noise
            // - Trackball: minimal deadzone; One-Euro handles jitter naturally
            const MAX_DELTA: f64 = 8000.0;
            let speed = (dx * dx + dy * dy).sqrt();
            let jitter_deadzone = if s.config.mode == InputMode::Trackpad {
                if speed < 120.0 {
                    18.0
                } else if speed < 420.0 {
                    10.0
                } else {
                    4.0
                }
            } else {
                // Trackball: only suppress digitizer noise floor
                if speed < 60.0 { 2.0 } else { 0.0 }
            };

            // Deadzone on magnitude — avoids axis-snapping on diagonal slow moves
            if speed < jitter_deadzone {
                return;
            }
            dx = dx.clamp(-MAX_DELTA, MAX_DELTA);
            dy = dy.clamp(-MAX_DELTA, MAX_DELTA);

            // One-Euro filter with actual inter-packet dt for correct frequency estimation.
            let now = std::time::Instant::now();
            let dt = s.last_touch_time
                .map(|t| now.duration_since(t).as_secs_f64().clamp(0.004, 0.1))
                .unwrap_or(1.0 / 60.0);
            s.last_touch_time = Some(now);
            dx = s.one_euro_dx.filter_dt(dx, dt);
            dy = s.one_euro_dy.filter_dt(dy, dt);

            if dx.abs() < 0.5 && dy.abs() < 0.5 {
                return;
            }

            let cfg = s.config.accel;
            let (sx, sy) = engine::accel::apply_curve_2d(dx, dy, &cfg);
            s.frac_x += sx;
            s.frac_y += sy;
            let ix = s.frac_x as i64;
            let iy = s.frac_y as i64;
            s.frac_x -= ix as f64;
            s.frac_y -= iy as f64;
            drop(s);
            if ix != 0 || iy != 0 {
                let _ = injector.move_relative(ix as f64, iy as f64);
            }
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
