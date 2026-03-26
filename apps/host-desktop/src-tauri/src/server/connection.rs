//! Session state, heartbeat tracking, and reconnect logic.

use std::net::SocketAddr;
use std::time::{Duration, Instant};

/// Timeout before considering a connection dead.
pub const HEARTBEAT_TIMEOUT: Duration = Duration::from_secs(3);
/// Interval at which client should send heartbeats.
pub const HEARTBEAT_INTERVAL: Duration = Duration::from_millis(500);

/// Connection state machine.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConnectionState {
    /// No active session.
    Disconnected,
    /// Handshake received, waiting for key exchange to complete.
    Handshaking,
    /// Fully connected and receiving packets.
    Connected,
}

/// Active session with a client device.
#[derive(Debug)]
pub struct Session {
    pub state: ConnectionState,
    pub peer_addr: SocketAddr,
    pub device_id: String,
    pub device_name: String,
    pub last_heartbeat: Instant,
    pub packets_received: u64,
    pub session_start: Instant,
}

impl Session {
    pub fn new(peer_addr: SocketAddr, device_id: String, device_name: String) -> Self {
        let now = Instant::now();
        Self {
            state: ConnectionState::Handshaking,
            peer_addr,
            device_id,
            device_name,
            last_heartbeat: now,
            packets_received: 0,
            session_start: now,
        }
    }

    /// Record a received packet (updates heartbeat timer).
    pub fn on_packet_received(&mut self) {
        self.last_heartbeat = Instant::now();
        self.packets_received += 1;
    }

    /// Check if the session has timed out (no heartbeat within HEARTBEAT_TIMEOUT).
    pub fn is_timed_out(&self) -> bool {
        self.last_heartbeat.elapsed() > HEARTBEAT_TIMEOUT
    }

    /// Mark session as fully connected.
    pub fn set_connected(&mut self) {
        self.state = ConnectionState::Connected;
    }

    /// Session uptime.
    pub fn uptime(&self) -> Duration {
        self.session_start.elapsed()
    }
}

/// Connection manager: tracks the current (at most one) active session.
#[derive(Debug, Default)]
pub struct ConnectionManager {
    pub session: Option<Session>,
}

impl ConnectionManager {
    pub fn new() -> Self {
        Self::default()
    }

    /// Start a new session (replaces any existing session).
    pub fn start_session(
        &mut self,
        peer_addr: SocketAddr,
        device_id: String,
        device_name: String,
    ) -> &mut Session {
        self.session = Some(Session::new(peer_addr, device_id, device_name));
        self.session.as_mut().unwrap()
    }

    /// Get the active session if connected and not timed out.
    pub fn active_session(&self) -> Option<&Session> {
        self.session
            .as_ref()
            .filter(|s| s.state == ConnectionState::Connected && !s.is_timed_out())
    }

    /// Check for timeout and clean up stale sessions.
    /// Returns true if a session was dropped.
    pub fn check_timeout(&mut self) -> bool {
        if let Some(ref s) = self.session {
            if s.is_timed_out() {
                log::warn!("Session {} timed out after {:?}", s.device_id, s.uptime());
                self.session = None;
                return true;
            }
        }
        false
    }

    pub fn is_connected(&self) -> bool {
        self.active_session().is_some()
    }

    pub fn disconnect(&mut self) {
        self.session = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::{IpAddr, Ipv4Addr};

    fn test_addr() -> SocketAddr {
        SocketAddr::new(IpAddr::V4(Ipv4Addr::new(192, 168, 1, 100)), 12345)
    }

    #[test]
    fn new_session_is_handshaking() {
        let s = Session::new(test_addr(), "dev1".into(), "Watch".into());
        assert_eq!(s.state, ConnectionState::Handshaking);
        assert!(!s.is_timed_out());
    }

    #[test]
    fn session_not_connected_until_set() {
        let mut mgr = ConnectionManager::new();
        let s = mgr.start_session(test_addr(), "dev1".into(), "Watch".into());
        assert!(mgr.active_session().is_none()); // still handshaking

        if let Some(ref mut s) = mgr.session {
            s.set_connected();
        }
        assert!(mgr.active_session().is_some());
    }

    #[test]
    fn packet_received_updates_heartbeat() {
        let mut s = Session::new(test_addr(), "dev1".into(), "Watch".into());
        let before = s.last_heartbeat;
        std::thread::sleep(Duration::from_millis(5));
        s.on_packet_received();
        assert!(s.last_heartbeat > before);
        assert_eq!(s.packets_received, 1);
    }

    #[test]
    fn disconnect_clears_session() {
        let mut mgr = ConnectionManager::new();
        mgr.start_session(test_addr(), "dev1".into(), "Watch".into());
        mgr.disconnect();
        assert!(mgr.session.is_none());
    }
}
