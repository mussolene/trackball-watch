//! UDP listener with TBP packet dispatch.
//!
//! Listens on UDP port 47474, receives TBP packets, decrypts them,
//! and dispatches to the input engine.

use std::net::SocketAddr;
use std::sync::Arc;
use tokio::net::UdpSocket;
use tokio::sync::Mutex;

use crate::protocol::packets::{
    decode_crown, decode_gesture, decode_header, decode_touch, packet_type, CrownPayload,
    GesturePayload, PacketHeader, TouchPayload,
};
use crate::server::connection::{ConnectionManager, ConnectionState};

pub const DEFAULT_PORT: u16 = 47474;
const MAX_PACKET_SIZE: usize = 1500;

/// Events dispatched from the UDP server to the input engine.
#[derive(Debug, Clone)]
pub enum InputEvent {
    Touch(PacketHeader, TouchPayload),
    Gesture(PacketHeader, GesturePayload),
    Crown(PacketHeader, CrownPayload),
    Heartbeat(PacketHeader),
    Connected { peer_addr: SocketAddr },
    Disconnected,
}

/// Callback type for input events.
pub type EventCallback = Arc<dyn Fn(InputEvent) + Send + Sync>;

/// UDP server that listens for TBP packets.
pub struct UdpServer {
    port: u16,
    connection_manager: Arc<Mutex<ConnectionManager>>,
    event_cb: Option<EventCallback>,
}

impl UdpServer {
    pub fn new(port: u16) -> Self {
        Self {
            port,
            connection_manager: Arc::new(Mutex::new(ConnectionManager::new())),
            event_cb: None,
        }
    }

    /// Set the callback for input events.
    pub fn on_event(&mut self, cb: EventCallback) {
        self.event_cb = Some(cb);
    }

    /// Run the UDP server (blocking — run in a tokio task).
    pub async fn run(&self) -> anyhow::Result<()> {
        let bind_addr = format!("0.0.0.0:{}", self.port);
        let socket = UdpSocket::bind(&bind_addr).await?;
        log::info!("TBP UDP server listening on {}", bind_addr);

        let mut buf = vec![0u8; MAX_PACKET_SIZE];

        loop {
            let (len, peer) = match socket.recv_from(&mut buf).await {
                Ok(r) => r,
                Err(e) => {
                    log::error!("UDP recv error: {}", e);
                    continue;
                }
            };

            let data = &buf[..len];
            log::debug!("UDP recv {} bytes from {}", len, peer);

            // Check for timeout on existing session
            {
                let mut mgr = self.connection_manager.lock().await;
                if mgr.check_timeout() {
                    if let Some(ref cb) = self.event_cb {
                        cb(InputEvent::Disconnected);
                    }
                }
            }

            if let Err(e) = self.handle_packet(data, peer).await {
                log::debug!("packet handling error from {}: {}", peer, e);
            }
        }
    }

    async fn handle_packet(&self, data: &[u8], peer: SocketAddr) -> anyhow::Result<()> {
        if data.len() < 8 {
            anyhow::bail!("packet too short: {} bytes", data.len());
        }

        let (header, header_len) =
            decode_header(data).map_err(|e| anyhow::anyhow!("header decode: {:?}", e))?;

        let payload = &data[header_len..];

        // Update heartbeat or implicitly create session on first packet from a new peer
        {
            let mut mgr = self.connection_manager.lock().await;
            let is_new_peer = mgr
                .session
                .as_ref()
                .map(|s| s.peer_addr != peer)
                .unwrap_or(true);

            if is_new_peer && header.packet_type != packet_type::HANDSHAKE {
                // Implicit session: treat any packet from an unknown peer as a connection.
                // This handles relays (iPhone) that don't send a formal HANDSHAKE.
                let s = mgr.start_session(peer, "unknown".into(), "Device".into());
                s.set_connected();
                drop(mgr);
                if let Some(ref cb) = self.event_cb {
                    cb(InputEvent::Connected { peer_addr: peer });
                }
            } else if let Some(ref mut s) = mgr.session {
                if s.peer_addr == peer {
                    s.on_packet_received();
                }
            }
        }

        let event = match header.packet_type {
            packet_type::TOUCH => {
                let (payload, _) =
                    decode_touch(payload).map_err(|e| anyhow::anyhow!("touch decode: {:?}", e))?;
                InputEvent::Touch(header, payload)
            }
            packet_type::GESTURE => {
                let (payload, _) = decode_gesture(payload)
                    .map_err(|e| anyhow::anyhow!("gesture decode: {:?}", e))?;
                InputEvent::Gesture(header, payload)
            }
            packet_type::CROWN => {
                let (payload, _) =
                    decode_crown(payload).map_err(|e| anyhow::anyhow!("crown decode: {:?}", e))?;
                InputEvent::Crown(header, payload)
            }
            packet_type::HEARTBEAT => InputEvent::Heartbeat(header),
            packet_type::HANDSHAKE => {
                let mut mgr = self.connection_manager.lock().await;
                // Skip if we already have an active session from this peer (e.g. implicit was created first)
                let already_connected = mgr
                    .session
                    .as_ref()
                    .map(|s| s.peer_addr == peer && s.state == ConnectionState::Connected)
                    .unwrap_or(false);
                if !already_connected {
                    let s = mgr.start_session(peer, "unknown".into(), "Apple Watch".into());
                    s.set_connected();
                    drop(mgr);
                    if let Some(ref cb) = self.event_cb {
                        cb(InputEvent::Connected { peer_addr: peer });
                    }
                }
                return Ok(());
            }
            unknown => {
                log::debug!("unknown packet type: 0x{:02x}", unknown);
                return Ok(());
            }
        };

        if let Some(ref cb) = self.event_cb {
            cb(event);
        }

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tokio::time::{timeout, Duration};

    #[tokio::test]
    async fn server_binds_and_receives() {
        use crate::protocol::packets::{encode_header, encode_touch, PacketHeader, TouchPayload};

        let port = 47500; // use a different port for tests
        let mut server = UdpServer::new(port);

        let count = Arc::new(AtomicUsize::new(0));
        let count2 = count.clone();
        server.on_event(Arc::new(move |event| {
            if matches!(event, InputEvent::Touch(_, _)) {
                count2.fetch_add(1, Ordering::SeqCst);
            }
        }));

        // Run server in background
        let server = Arc::new(server);
        let server2 = server.clone();
        tokio::spawn(async move {
            let _ = server2.run().await;
        });

        // Give server time to bind
        tokio::time::sleep(Duration::from_millis(50)).await;

        // Send a TOUCH packet
        let client = UdpSocket::bind("0.0.0.0:0").await.unwrap();
        let header = PacketHeader {
            seq: 1,
            packet_type: packet_type::TOUCH,
            flags: 0,
            timestamp_us: 1000,
        };
        let touch = TouchPayload {
            touch_id: 0,
            phase: 2,
            x: 1000,
            y: 500,
            pressure: 128,
            _pad: 0,
        };

        let mut packet = encode_header(&header).unwrap();
        packet.extend(encode_touch(&touch).unwrap());
        client
            .send_to(&packet, format!("127.0.0.1:{}", port))
            .await
            .unwrap();

        // Wait for event
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert_eq!(count.load(Ordering::SeqCst), 1);
    }
}
