pub mod engine;
pub mod injector;
pub mod protocol;
pub mod server;
pub mod settings;
pub mod trace_file;

use sha2::{Digest, Sha256};
use std::net::Ipv4Addr;
use std::sync::{Arc, Mutex};
use tauri::{
    image::Image,
    menu::{Menu, MenuItem},
    tray::TrayIconBuilder,
    Emitter, Manager,
};

use engine::pointing_device::{DriverMode, PointingDeviceState};
use engine::trackball::TrackballState;
use engine::virtual_ball::{MotionDecision, MotionTelemetry};
use protocol::packets::{GestureType, TouchPhase};
use server::udp::{InputEvent, UdpServer};
use settings::config::{AppConfig, InputMode};

const DEFAULT_MOTION_DEBUG: bool = true;

/// Shared application state (input pipeline + connection info).
struct AppState {
    config: AppConfig,
    pointing_device: PointingDeviceState,
    trackball: TrackballState,
    /// Counter for throttling STATE_FEEDBACK packets (~10 Hz = every 6 coast frames).
    feedback_frame_count: u8,
    connected_peer: Option<ConnectedPeer>,
    /// Send raw packets to the connected peer via the UDP server socket.
    udp_tx: Option<tokio::sync::mpsc::UnboundedSender<Vec<u8>>>,
    motion_debug: bool,
    left_button_held: bool,
    left_button_drag_active: bool,
}

impl AppState {
    fn new(config: AppConfig) -> Self {
        let trackball = TrackballState::new(config.trackball_friction, 0.5);
        Self {
            config,
            pointing_device: PointingDeviceState::default(),
            trackball,
            feedback_frame_count: 0,
            connected_peer: None,
            udp_tx: None,
            motion_debug: std::env::var("TRACKBALL_DEBUG_MOTION")
                .map(|v| v != "0")
                .unwrap_or(DEFAULT_MOTION_DEBUG),
            left_button_held: false,
            left_button_drag_active: false,
        }
    }
}

fn log_motion_telemetry(prefix: &str, telemetry: MotionTelemetry) {
    match telemetry.decision {
        MotionDecision::Applied => log::debug!(
            "{prefix}: in=({:.4},{:.4}) speed={:.4} gain={:.4} out=({:.4},{:.4})",
            telemetry.input_dx,
            telemetry.input_dy,
            telemetry.input_speed,
            telemetry.gain,
            telemetry.output_dx,
            telemetry.output_dy
        ),
        MotionDecision::Deadzone => log::debug!(
            "{prefix}: in=({:.4},{:.4}) speed={:.4} -> deadzone (thresholded)",
            telemetry.input_dx,
            telemetry.input_dy,
            telemetry.input_speed
        ),
        MotionDecision::ZeroOutput => log::debug!(
            "{prefix}: in=({:.4},{:.4}) speed={:.4} gain={:.4} -> zero output",
            telemetry.input_dx,
            telemetry.input_dy,
            telemetry.input_speed,
            telemetry.gain
        ),
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

#[derive(serde::Serialize)]
struct SaveConfigResult {
    /// UDP listener is started once at launch; new port needs app restart.
    needs_app_restart: bool,
}

/// macOS Accessibility + which binary TCC must allow (dev vs `/Applications` are different rows).
#[derive(serde::Serialize, Clone)]
struct AccessibilityStatus {
    trusted: bool,
    executable_path: String,
}

// ── Tauri commands ────────────────────────────────────────────────────────────

#[tauri::command]
fn get_config(state: tauri::State<Arc<Mutex<AppState>>>) -> AppConfig {
    state.lock().unwrap().config.clone()
}

#[tauri::command]
fn save_config(
    config: AppConfig,
    state: tauri::State<Arc<Mutex<AppState>>>,
) -> Result<SaveConfigResult, String> {
    if !(1024..=65535).contains(&config.udp_port) {
        return Err("UDP port must be between 1024 and 65535".into());
    }
    let old_port = state.lock().unwrap().config.udp_port;
    let needs_app_restart = old_port != config.udp_port;
    config.save().map_err(|e| e.to_string())?;
    let mut pending_mode_push: Option<(
        tokio::sync::mpsc::UnboundedSender<Vec<u8>>,
        InputMode,
        f64,
    )> = None;
    {
        let mut s = state.lock().unwrap();
        s.pointing_device.reset();
        s.trackball = TrackballState::new(config.trackball_friction, 0.5);
        s.config = config;
        if let Some(tx) = s.udp_tx.clone() {
            pending_mode_push = Some((
                tx,
                s.config.mode,
                s.config.trackball_friction,
            ));
        }
    }
    if let Some((tx, mode, friction)) = pending_mode_push {
        if let Err(e) = send_mode_packet(&tx, mode, friction) {
            log::warn!("mode push after save failed: {}", e);
        }
    }
    Ok(SaveConfigResult { needs_app_restart })
}

/// Accessibility trust + resolved executable path (for System Settings → Accessibility).
#[tauri::command]
fn check_accessibility() -> AccessibilityStatus {
    #[cfg(target_os = "macos")]
    {
        AccessibilityStatus {
            trusted: injector::macos::MacOSInjector::has_accessibility_permission(),
            executable_path: std::env::current_exe()
                .map(|p| p.display().to_string())
                .unwrap_or_else(|_| "(unknown path)".to_string()),
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        AccessibilityStatus {
            trusted: true,
            executable_path: String::new(),
        }
    }
}

/// Ask macOS to show the standard Accessibility trust prompt (if not already trusted).
#[tauri::command]
fn request_accessibility_prompt() -> bool {
    #[cfg(target_os = "macos")]
    {
        injector::macos::MacOSInjector::prompt_accessibility_permission()
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
        send_mode_packet(
            tx,
            s.config.mode,
            s.config.trackball_friction,
        )?;
    }
    Ok(())
}

fn send_mode_packet(
    tx: &tokio::sync::mpsc::UnboundedSender<Vec<u8>>,
    mode: InputMode,
    trackball_friction: f64,
) -> Result<(), String> {
    use crate::protocol::packets::{encode_header, packet_type, PacketHeader};
    let mode_byte: u8 = if mode == InputMode::Trackball { 1 } else { 0 };
    // Centi-units (50–99 → 0.50–0.99); matches watch visual coast damping.
    let friction_byte = ((trackball_friction.clamp(0.5, 0.99) * 100.0).round() as u8).clamp(50, 99);
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
    trace_file::reset();
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or(
        if DEFAULT_MOTION_DEBUG {
            "debug"
        } else {
            "info"
        },
    ))
    .init();
    trace_file::append_line("host launch");

    #[cfg(target_os = "macos")]
    {
        let exe = std::env::current_exe()
            .map(|p| p.display().to_string())
            .unwrap_or_else(|_| "(unknown path)".to_string());
        if !injector::macos::MacOSInjector::has_accessibility_permission() {
            // System sheet: “TrackBall Watch would like to control this computer…”
            let _ = injector::macos::MacOSInjector::prompt_accessibility_permission();
        }
        let trusted = injector::macos::MacOSInjector::has_accessibility_permission();
        trace_file::append_line(format!("accessibility trusted={trusted}"));
        log::info!(
            "macOS input injection: Accessibility trusted={} for {}",
            trusted,
            exe
        );
        if !trusted {
            log::warn!(
                "Accessibility is off for this executable — cursor/clicks will not work. \
                 Use the system prompt or System Settings → Privacy & Security → Accessibility. \
                 Dev (`target/debug/…`) and `/Applications/…` are separate entries."
            );
        }
    }

    let config = AppConfig::load();
    let udp_port = config.udp_port;
    let device_id = config.device_id.clone();
    let app_state = Arc::new(Mutex::new(AppState::new(config)));
    let app_state_udp = app_state.clone();

    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _argv, _cwd| {
            if let Some(w) = app.get_webview_window("main") {
                let _ = w.show();
                let _ = w.set_focus();
            }
        }))
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
            request_accessibility_prompt,
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
            #[cfg(target_os = "macos")]
            let a11y_item = MenuItem::with_id(
                app,
                "a11y",
                "Accessibility (enable cursor control)…",
                true,
                None::<&str>,
            )?;
            let menu = {
                #[cfg(target_os = "macos")]
                {
                    Menu::with_items(
                        app,
                        &[
                            &show_qr_item,
                            &settings_item,
                            &a11y_item,
                            &disconnect_item,
                            &quit,
                        ],
                    )?
                }
                #[cfg(not(target_os = "macos"))]
                {
                    Menu::with_items(
                        app,
                        &[&show_qr_item, &settings_item, &disconnect_item, &quit],
                    )?
                }
            };

            let mut tray_builder = TrayIconBuilder::with_id("main-tray");
            if let Ok(icon) = Image::from_bytes(include_bytes!("../icons/tray-icon.png")) {
                tray_builder = tray_builder.icon(icon);
            } else if let Some(icon) = app.default_window_icon().cloned() {
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
                    #[cfg(target_os = "macos")]
                    "a11y" => {
                        let _ = injector::macos::MacOSInjector::prompt_accessibility_permission();
                        injector::macos::MacOSInjector::open_accessibility_settings();
                        if let Some(win) = app.get_webview_window("main") {
                            let _ = win.show();
                            let _ = win.set_focus();
                        }
                    }
                    _ => {}
                })
                .build(app)?;

            update_tray(app.handle(), false, None);

            // ── UDP server ────────────────────────────────────────────────────
            let state_for_coast = app_state_udp.clone();
            let state_for_thread = app_state_udp;
            let app_for_coast = app_handle.clone();
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
                        trackball_coast_step(&state_for_coast, dt, &app_for_coast);
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
        #[cfg(target_os = "macos")]
        let a11y_ok = injector::macos::MacOSInjector::has_accessibility_permission();
        #[cfg(not(target_os = "macos"))]
        let a11y_ok = true;

        let mut tooltip = if connected {
            format!(
                "TrackBall Watch — Connected{}",
                peer_addr.map(|a| format!(" ({})", a)).unwrap_or_default()
            )
        } else {
            "TrackBall Watch — Disconnected".to_string()
        };
        #[cfg(target_os = "macos")]
        if !a11y_ok {
            tooltip.push_str(" — Accessibility OFF (cursor won’t move)");
        }
        let _ = tray.set_tooltip(Some(&tooltip));
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

/// Dispatch a cursor/input action.
///
/// CGEventCreate/CGEventPost are CoreGraphics (not AppKit) and are
/// documented thread-safe — they can be called from any OS thread,
/// including Tokio workers and background coast threads.
/// Posting to the main-thread run-loop (run_on_main_thread) was adding
/// up to one full display frame (~16 ms) of extra latency per event.
#[cfg(target_os = "macos")]
fn dispatch_input_action<F>(_app: &tauri::AppHandle, f: F)
where
    F: FnOnce() + Send + 'static,
{
    f()
}

#[cfg(not(target_os = "macos"))]
fn dispatch_input_action<F>(_app: &tauri::AppHandle, f: F)
where
    F: FnOnce() + Send + 'static,
{
    f();
}

/// Advance trackball inertia at ~60 Hz when coasting (FLING already set velocity).
fn trackball_coast_step(state: &Arc<Mutex<AppState>>, dt: f64, app: &tauri::AppHandle) {
    let mut s = match state.lock() {
        Ok(g) => g,
        Err(_) => return,
    };
    if s.config.mode != InputMode::Trackball || !s.trackball.is_active() {
        return;
    }
    let (dx, dy) = s.trackball.tick(dt);
    if dx == 0.0 && dy == 0.0 && !s.trackball.is_active() {
        // Motion just stopped — send one final feedback so watch stops animating
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
    // Sub-pixel deltas: macOS CGEvent mouse location uses CGFloat; integer steps felt like 2–3 mm jumps.
    // Throttle STATE_FEEDBACK to ~10 Hz (every 6 frames at 60 Hz)
    s.feedback_frame_count = s.feedback_frame_count.wrapping_add(1);
    let should_send_feedback = s.feedback_frame_count % 6 == 0;
    let udp_tx = if should_send_feedback {
        s.udp_tx.clone()
    } else {
        None
    };
    drop(s);
    if sx != 0.0 || sy != 0.0 {
        dispatch_input_action(app, move || match injector::create_injector() {
            Ok(inj) => {
                let _ = inj.move_relative(sx, sy);
            }
            Err(e) => log::warn!("Injector unavailable (coast): {}", e),
        });
    }
    if let Some(tx) = udp_tx {
        let _ = send_state_feedback(&tx, is_coasting, vx, vy);
    }
}

fn reset_touch_pipeline(s: &mut AppState) {
    s.pointing_device.reset();
}

fn process_trackpad_touch(
    s: &mut AppState,
    header: protocol::packets::PacketHeader,
    payload: protocol::packets::TouchPayload,
) -> Option<(f64, f64)> {
    let phase = TouchPhase::try_from(payload.phase).unwrap_or(TouchPhase::Moved);
    if matches!(phase, TouchPhase::Ended | TouchPhase::Cancelled) {
        reset_touch_pipeline(s);
        s.trackball.stop();
        return None;
    }
    if phase == TouchPhase::Began {
        s.trackball.stop();
    }
    if !s.pointing_device.accept_sequence(header.seq) {
        if s.motion_debug {
            log::debug!(
                "trackpad: dropped stale/duplicate touch packet seq={}",
                header.seq
            );
        }
        return None;
    }
    let output = s
        .pointing_device
        .handle_touch(DriverMode::Trackpad, payload);
    if let Some(output) = output {
        if s.motion_debug {
            log_motion_telemetry("trackpad", output.telemetry);
        }
        return Some((output.dx, output.dy));
    }
    None
}

fn process_trackball_touch(
    s: &mut AppState,
    header: protocol::packets::PacketHeader,
    payload: protocol::packets::TouchPayload,
) -> Option<(f64, f64)> {
    let phase = TouchPhase::try_from(payload.phase).unwrap_or(TouchPhase::Moved);
    if s.motion_debug {
        log::debug!(
            "trackball packet: seq={} phase={:?} raw=({}, {}) pressure={}",
            header.seq,
            phase,
            payload.x,
            payload.y,
            payload.pressure
        );
        trace_file::append_line(format!(
            "trackball packet seq={} phase={:?} raw=({}, {}) pressure={}",
            header.seq, phase, payload.x, payload.y, payload.pressure
        ));
    }

    if matches!(phase, TouchPhase::Ended | TouchPhase::Cancelled) {
        reset_touch_pipeline(s);
        return None;
    }

    if !s.pointing_device.accept_sequence(header.seq) {
        if s.motion_debug {
            log::debug!(
                "trackball: dropped stale/duplicate touch packet seq={}",
                header.seq
            );
            trace_file::append_line(format!("trackball dropped stale seq={}", header.seq));
        }
        return None;
    }

    if phase == TouchPhase::Began {
        s.trackball.stop();
        reset_touch_pipeline(s);
    }

    // In trackball mode the watch already streams a virtual surface-contact point.
    // Treat deltas as physical rolling displacement, not as a noisy pointer input stream.
    let output = s
        .pointing_device
        .handle_touch(DriverMode::Trackball, payload);
    let Some(output) = output else {
        return None;
    };
    if s.motion_debug {
        log_motion_telemetry("trackball", output.telemetry);
        trace_file::append_line(format!(
            "trackball output dx={:.4} dy={:.4} decision={:?}",
            output.dx, output.dy, output.telemetry.decision
        ));
    }

    // True trackball semantics:
    // - while the finger is rolling the ball, the cursor follows only the current angular change
    // - if the ball stops under the finger, the cursor stops immediately
    // Inertia is started only by an explicit FLING gesture after release.
    Some((output.dx, output.dy))
}

// ── Input event handler ───────────────────────────────────────────────────────

fn handle_input_event(event: InputEvent, state: &Arc<Mutex<AppState>>, app: &tauri::AppHandle) {
    match event {
        InputEvent::Connected { peer_addr } => {
            log::info!("Device connected: {}", peer_addr);
            trace_file::append_line(format!("device connected {}", peer_addr));
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

            #[cfg(target_os = "macos")]
            if !injector::macos::MacOSInjector::has_accessibility_permission() {
                let _ = app.emit(
                    "accessibility_required",
                    "This app build needs its own Accessibility permission. \
                     System Settings → Privacy & Security → Accessibility → enable “TrackBall Watch” \
                     (the one from Applications, not the terminal/debug build).",
                );
                log::warn!(
                    "Device connected but Accessibility is off for this executable — UDP works, cursor injection is blocked."
                );
            }

            // Ensure watch mode reflects current desktop mode right after link-up.
            let mode_push = {
                let s = state.lock().unwrap();
                s.udp_tx.clone().map(|tx| {
                    (
                        tx,
                        s.config.mode,
                        s.config.trackball_friction,
                    )
                })
            };
            if let Some((tx, mode, friction)) = mode_push {
                let _ = send_mode_packet(&tx, mode, friction);
            }
        }

        InputEvent::Disconnected => {
            log::info!("Device disconnected");
            trace_file::append_line("device disconnected");
            let should_release_left_button = {
                let mut s = state.lock().unwrap();
                let should_release = s.left_button_held;
                s.left_button_held = false;
                s.left_button_drag_active = false;
                s.connected_peer = None;
                s.trackball.stop();
                reset_touch_pipeline(&mut s);
                should_release
            };
            if should_release_left_button {
                dispatch_input_action(app, || match injector::create_injector() {
                    Ok(i) => {
                        if let Err(e) = i.left_button_up() {
                            log::warn!("Left button release on disconnect failed: {}", e);
                        }
                    }
                    Err(e) => log::warn!("Injector unavailable: {}", e),
                });
            }
            let payload = ConnectionStatusPayload {
                state: "disconnected".into(),
                peer: None,
            };
            let _ = app.emit("connection_status_changed", payload);
            update_tray(app, false, None);
        }

        InputEvent::Heartbeat(_) => {}

        InputEvent::Touch(header, payload) => {
            let mut s = state.lock().unwrap();
            let phase = TouchPhase::try_from(payload.phase).unwrap_or(TouchPhase::Moved);
            match s.config.mode {
                InputMode::Trackpad => {
                    let output = process_trackpad_touch(&mut s, header, payload);
                    let should_finish_drag = s.left_button_drag_active
                        && s.left_button_held
                        && matches!(phase, TouchPhase::Ended | TouchPhase::Cancelled);
                    if should_finish_drag {
                        s.left_button_held = false;
                        s.left_button_drag_active = false;
                    }
                    drop(s);
                    if let Some((sx, sy)) = output {
                        dispatch_input_action(app, move || match injector::create_injector() {
                            Ok(inj) => {
                                let _ = inj.move_relative(sx, sy);
                            }
                            Err(e) => log::warn!("Injector unavailable: {}", e),
                        });
                    }
                    if should_finish_drag {
                        dispatch_input_action(app, move || match injector::create_injector() {
                            Ok(i) => {
                                if let Err(e) = i.left_button_up() {
                                    log::warn!("Left button release after drag failed: {}", e);
                                }
                                if let Err(e) = i.right_click() {
                                    log::warn!("Right click after long press failed: {}", e);
                                }
                            }
                            Err(e) => log::warn!("Injector unavailable: {}", e),
                        });
                    }
                }
                InputMode::Trackball => {
                    let output = process_trackball_touch(&mut s, header, payload);
                    let should_finish_drag = s.left_button_drag_active
                        && s.left_button_held
                        && matches!(phase, TouchPhase::Ended | TouchPhase::Cancelled);
                    if should_finish_drag {
                        s.left_button_held = false;
                        s.left_button_drag_active = false;
                    }
                    drop(s);
                    if let Some((sx, sy)) = output {
                        dispatch_input_action(app, move || match injector::create_injector() {
                            Ok(inj) => {
                                let _ = inj.move_relative(sx, sy);
                            }
                            Err(e) => log::warn!("Injector unavailable: {}", e),
                        });
                    }
                    if should_finish_drag {
                        dispatch_input_action(app, move || match injector::create_injector() {
                            Ok(i) => {
                                if let Err(e) = i.left_button_up() {
                                    log::warn!("Left button release after drag failed: {}", e);
                                }
                                if let Err(e) = i.right_click() {
                                    log::warn!("Right click after long press failed: {}", e);
                                }
                            }
                            Err(e) => log::warn!("Injector unavailable: {}", e),
                        });
                    }
                }
            }
        }

        InputEvent::Gesture(_, payload) => {
            let mut s = state.lock().unwrap();
            match GestureType::try_from(payload.gesture_type).ok() {
                Some(GestureType::Tap) => {
                    log::info!("Gesture received: tap");
                    if s.left_button_held {
                        drop(s);
                        return;
                    }
                    drop(s);
                    dispatch_input_action(app, move || match injector::create_injector() {
                        Ok(i) => {
                            let result = i.left_click();
                            if let Err(e) = result {
                                log::warn!("Tap injection failed: {}", e);
                            }
                        }
                        Err(e) => log::warn!("Injector unavailable: {}", e),
                    });
                }
                Some(GestureType::DoubleTap) => {
                    log::info!("Gesture received: double tap");
                    drop(s);
                    dispatch_input_action(app, move || match injector::create_injector() {
                        Ok(i) => {
                            if let Err(e) = i.double_click() {
                                log::warn!("Double-click injection failed: {}", e);
                            }
                        }
                        Err(e) => log::warn!("Injector unavailable: {}", e),
                    });
                }
                Some(GestureType::LongPress) => {
                    log::info!("Gesture received: long press");
                    if s.left_button_held {
                        drop(s);
                        return;
                    }
                    s.left_button_held = true;
                    s.left_button_drag_active = true;
                    drop(s);
                    dispatch_input_action(app, move || match injector::create_injector() {
                        Ok(i) => {
                            let result = i.left_button_down();
                            if let Err(e) = result {
                                log::warn!("Left hold start injection failed: {}", e);
                            }
                        }
                        Err(e) => log::warn!("Injector unavailable: {}", e),
                    });
                }
                Some(GestureType::Fling) if s.config.mode == InputMode::Trackball => {
                    s.trackball
                        .fling(payload.param1 as f64, payload.param2 as f64);
                }
                _ => {}
            }
        }

        InputEvent::Crown(_, payload) => {
            let lines = payload.delta as f64 / 100.0;
            dispatch_input_action(app, move || match injector::create_injector() {
                Ok(i) => {
                    let _ = i.scroll_vertical(lines);
                }
                Err(e) => log::warn!("Injector unavailable: {}", e),
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::pointing_device::{DriverMode, PointingDeviceState};
    use crate::protocol::packets::{packet_type, PacketHeader, TouchPayload};

    fn header(seq: u16) -> PacketHeader {
        PacketHeader {
            seq,
            packet_type: packet_type::TOUCH,
            flags: 0,
            timestamp_us: u32::from(seq),
        }
    }

    fn touch_payload(phase: TouchPhase, x: i16, y: i16) -> TouchPayload {
        let pressure = if matches!(phase, TouchPhase::Ended | TouchPhase::Cancelled) {
            0
        } else {
            180
        };
        TouchPayload {
            touch_id: 0,
            phase: phase as u8,
            x,
            y,
            pressure,
            _pad: 0,
        }
    }

    fn trackball_state() -> AppState {
        let mut cfg = AppConfig::default();
        cfg.mode = InputMode::Trackball;
        AppState::new(cfg)
    }

    fn trackpad_state() -> AppState {
        let mut cfg = AppConfig::default();
        cfg.mode = InputMode::Trackpad;
        AppState::new(cfg)
    }

    #[test]
    fn trackpad_micro_adjustments_accumulate_into_path() {
        let mut driver = PointingDeviceState::default();
        let mut cursor_x = 0.0;

        assert_eq!(
            driver
                .handle_touch(DriverMode::Trackpad, touch_payload(TouchPhase::Began, 0, 0))
                .is_some(),
            false
        );
        for step in [8_i16, 16, 24, 32, 40] {
            if let Some(output) = driver.handle_touch(
                DriverMode::Trackpad,
                touch_payload(TouchPhase::Moved, step, 0),
            ) {
                cursor_x += output.dx;
            }
        }

        assert!(cursor_x > 0.03, "micro adjustments were lost: {}", cursor_x);
        assert!(
            cursor_x < 0.25,
            "micro adjustments are still too aggressive: {}",
            cursor_x
        );
    }

    #[test]
    fn trackpad_precision_motion_uses_lower_gain_than_fast_motion() {
        let cfg = PointingDeviceState::config_for(DriverMode::Trackpad);
        let slow = cfg.cursor_delta(0.02, 0.0).expect("slow motion");
        let fast = cfg.cursor_delta(1.0, 0.0).expect("fast motion");
        assert!(
            slow.0 / 0.02 < fast.0 / 1.0,
            "slow motion should use a lower precision gain"
        );
    }

    #[test]
    fn trackball_precision_motion_uses_lower_gain_than_fast_motion() {
        let cfg = PointingDeviceState::config_for(DriverMode::Trackball);
        let slow = cfg.cursor_delta(0.07, 0.0).expect("slow motion");
        let fast = cfg.cursor_delta(1.0, 0.0).expect("fast motion");
        assert!(
            slow.0 / 0.07 < fast.0 / 1.0,
            "slow motion should use a lower precision gain"
        );
    }

    #[test]
    fn trackpad_stops_immediately_when_surface_stops() {
        let mut state = trackpad_state();

        assert_eq!(
            process_trackpad_touch(
                &mut state,
                header(1),
                touch_payload(TouchPhase::Began, 0, 0)
            ),
            None
        );
        let first = process_trackpad_touch(
            &mut state,
            header(2),
            touch_payload(TouchPhase::Moved, 120, 0),
        );
        let second = process_trackpad_touch(
            &mut state,
            header(3),
            touch_payload(TouchPhase::Moved, 120, 0),
        );

        assert!(first.is_some(), "initial movement should move the cursor");
        assert_eq!(
            second, None,
            "cursor must stop when surface delta becomes zero"
        );
    }

    #[test]
    fn trackpad_diagonal_motion_stays_diagonal() {
        let mut state = trackpad_state();
        let mut cursor = (0.0, 0.0);

        assert_eq!(
            process_trackpad_touch(
                &mut state,
                header(1),
                touch_payload(TouchPhase::Began, 0, 0)
            ),
            None
        );
        for (seq, (x, y)) in [
            (2_u16, (100_i16, 100_i16)),
            (3, (200, 200)),
            (4, (300, 300)),
        ] {
            if let Some((dx, dy)) = process_trackpad_touch(
                &mut state,
                header(seq),
                touch_payload(TouchPhase::Moved, x, y),
            ) {
                cursor.0 += dx;
                cursor.1 += dy;
            }
        }

        let ratio = cursor.0 / cursor.1;
        assert!(
            ratio > 0.95 && ratio < 1.05,
            "diagonal skew too large: {:?}",
            cursor
        );
    }

    #[test]
    fn trackball_touch_stops_after_end_even_if_position_is_held() {
        let mut state = trackball_state();

        assert_eq!(
            process_trackball_touch(
                &mut state,
                header(1),
                touch_payload(TouchPhase::Began, 0, 0)
            ),
            None
        );
        assert!(process_trackball_touch(
            &mut state,
            header(2),
            touch_payload(TouchPhase::Moved, 64, 0)
        )
        .is_some());
        assert_eq!(
            process_trackball_touch(
                &mut state,
                header(3),
                touch_payload(TouchPhase::Ended, 64, 0)
            ),
            None
        );
        assert_eq!(
            process_trackball_touch(
                &mut state,
                header(4),
                touch_payload(TouchPhase::Began, 64, 0)
            ),
            None
        );
    }

    #[test]
    fn trackball_drops_out_of_order_touch_packet() {
        let mut state = trackball_state();

        assert_eq!(
            process_trackball_touch(
                &mut state,
                header(10),
                touch_payload(TouchPhase::Began, 0, 0)
            ),
            None
        );
        let forward = process_trackball_touch(
            &mut state,
            header(11),
            touch_payload(TouchPhase::Moved, 64, 0),
        );
        let stale = process_trackball_touch(
            &mut state,
            header(10),
            touch_payload(TouchPhase::Moved, 32, 0),
        );

        assert!(forward.is_some(), "newer packet should move cursor");
        assert_eq!(stale, None, "stale packet must be ignored");
    }
}
