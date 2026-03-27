//! mDNS advertisement for `_tbp._udp.local.`.
//!
//! On macOS the pure-Rust `mdns_sd` crate does not integrate with the system's
//! mDNSResponder, so iOS `NWBrowser` cannot discover the service.  We use the
//! native `dns-sd -R` subprocess instead, which registers through mDNSResponder
//! and is visible to every Apple device on the same network.

use std::process::{Child, Command};

/// mDNS advertiser for the TBP service.
pub struct MdnsAdvertiser {
    children: Vec<Child>,
}

impl MdnsAdvertiser {
    pub fn new() -> Result<Self, std::io::Error> {
        Ok(Self {
            children: Vec::new(),
        })
    }

    /// Advertise `_tbp._udp.local.` on `port` for each LAN interface host.
    pub fn advertise_many(
        &mut self,
        port: u16,
        device_id: &str,
        hosts: &[(String, String)],
    ) -> Result<(), std::io::Error> {
        let instance_name = format!("TrackBall-{}", &device_id[..8.min(device_id.len())]);

        if hosts.is_empty() {
            let child = Command::new("dns-sd")
                .args([
                    "-R",
                    &instance_name,
                    "_tbp._udp",
                    "local",
                    &port.to_string(),
                    &format!("device_id={device_id}"),
                    "host=",
                    "iface=",
                    "version=1",
                ])
                .spawn()?;
            self.children.push(child);
            log::info!("mDNS: advertising {} on port {}", instance_name, port);
            return Ok(());
        }

        for (host, iface) in hosts {
            let service_name = format!("{}-{}", instance_name, iface);
            let child = Command::new("dns-sd")
                .args([
                    "-R",
                    &service_name,
                    "_tbp._udp",
                    "local",
                    &port.to_string(),
                    &format!("device_id={device_id}"),
                    &format!("host={host}"),
                    &format!("iface={iface}"),
                    "version=1",
                ])
                .spawn()?;
            self.children.push(child);
            log::info!("mDNS: advertising {} on {}:{}", service_name, host, port);
        }
        Ok(())
    }

    pub fn stop(&mut self) {
        for mut child in self.children.drain(..) {
            let _ = child.kill();
        }
    }
}

impl Drop for MdnsAdvertiser {
    fn drop(&mut self) {
        self.stop();
    }
}
