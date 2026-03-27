//! mDNS advertisement for `_tbp._udp.local.`.
//!
//! On macOS the pure-Rust `mdns_sd` crate does not integrate with the system's
//! mDNSResponder, so iOS `NWBrowser` cannot discover the service.  We use the
//! native `dns-sd -R` subprocess instead, which registers through mDNSResponder
//! and is visible to every Apple device on the same network.

use std::process::{Child, Command};

/// mDNS advertiser for the TBP service.
pub struct MdnsAdvertiser {
    child: Option<Child>,
}

impl MdnsAdvertiser {
    pub fn new() -> Result<Self, std::io::Error> {
        Ok(Self { child: None })
    }

    /// Advertise `_tbp._udp.local.` on `port` with a human-readable instance name.
    pub fn advertise(&mut self, port: u16, device_id: &str) -> Result<(), std::io::Error> {
        let instance_name = format!("TrackBall-{}", &device_id[..8.min(device_id.len())]);

        let child = Command::new("dns-sd")
            .args([
                "-R",
                &instance_name,
                "_tbp._udp",
                "local",
                &port.to_string(),
                &format!("device_id={device_id}"),
                "version=1",
            ])
            .spawn()?;

        self.child = Some(child);
        log::info!("mDNS: advertising {} on port {}", instance_name, port);
        Ok(())
    }

    pub fn stop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
        }
    }
}

impl Drop for MdnsAdvertiser {
    fn drop(&mut self) {
        self.stop();
    }
}
