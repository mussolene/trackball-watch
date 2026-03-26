//! mDNS advertisement for `_tbp._udp.local`.
//!
//! Advertises the desktop host so iPhone companion apps can discover it
//! without manual IP configuration.

use mdns_sd::{ServiceDaemon, ServiceInfo};
use std::collections::HashMap;

const SERVICE_TYPE: &str = "_tbp._udp.local.";
const TBP_VERSION: &str = "1";

/// mDNS advertiser for the TBP service.
pub struct MdnsAdvertiser {
    daemon: ServiceDaemon,
    service_fullname: Option<String>,
}

impl MdnsAdvertiser {
    /// Create and start the mDNS daemon.
    pub fn new() -> Result<Self, mdns_sd::Error> {
        let daemon = ServiceDaemon::new()?;
        Ok(Self {
            daemon,
            service_fullname: None,
        })
    }

    /// Advertise the service on the given port with a unique device_id.
    pub fn advertise(&mut self, port: u16, device_id: &str) -> Result<(), mdns_sd::Error> {
        let instance_name = format!("TrackBall-{}", &device_id[..8.min(device_id.len())]);

        let mut properties = HashMap::new();
        properties.insert("version".to_string(), TBP_VERSION.to_string());
        properties.insert("device_id".to_string(), device_id.to_string());

        let service = ServiceInfo::new(
            SERVICE_TYPE,
            &instance_name,
            &format!("{}.local.", hostname()),
            "",
            port,
            properties,
        )?;

        let fullname = service.get_fullname().to_string();
        self.daemon.register(service)?;
        self.service_fullname = Some(fullname);

        log::info!("mDNS: advertising {} on port {}", instance_name, port);
        Ok(())
    }

    /// Stop advertising.
    pub fn stop(&mut self) {
        if let Some(ref name) = self.service_fullname.take() {
            if let Err(e) = self.daemon.unregister(name) {
                log::warn!("mDNS unregister error: {}", e);
            }
        }
    }
}

impl Drop for MdnsAdvertiser {
    fn drop(&mut self) {
        self.stop();
    }
}

fn hostname() -> String {
    std::env::var("HOSTNAME")
        .or_else(|_| {
            // Fallback: read from system
            std::fs::read_to_string("/etc/hostname")
                .map(|s| s.trim().to_string())
        })
        .unwrap_or_else(|_| "localhost".to_string())
}
