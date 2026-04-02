//! mDNS via Apple `dns-sd -R` (system mDNSResponder). Required on macOS so iPhone
//! discovers the host reliably.

use super::common::{sanitize_txt_ascii, service_instance_name};
use std::io;
use std::process::{Child, Command};

fn dns_sd_command() -> Command {
    Command::new("dns-sd")
}

/// mDNS advertiser for the TBP service.
pub struct MdnsAdvertiser {
    children: Vec<Child>,
}

impl MdnsAdvertiser {
    pub fn new() -> Result<Self, io::Error> {
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
    ) -> Result<(), io::Error> {
        let instance_base = format!("TrackBall-{}", &device_id[..8.min(device_id.len())]);

        if hosts.is_empty() {
            let child = dns_sd_command()
                .args([
                    "-R",
                    &instance_base,
                    "_tbp._udp",
                    "local",
                    &port.to_string(),
                    &format!("device_id={device_id}"),
                    &format!("port={port}"),
                    "host=",
                    "iface=",
                    "version=1",
                ])
                .spawn()?;
            self.children.push(child);
            log::info!("mDNS: advertising {} on port {}", instance_base, port);
            return Ok(());
        }

        for (index, (host, iface)) in hosts.iter().enumerate() {
            let service_name = service_instance_name(&instance_base, index);
            let iface_txt = sanitize_txt_ascii(iface);
            log::debug!("mDNS iface raw (index {index}): {iface}");
            let child = dns_sd_command()
                .args([
                    "-R",
                    &service_name,
                    "_tbp._udp",
                    "local",
                    &port.to_string(),
                    &format!("device_id={device_id}"),
                    &format!("port={port}"),
                    &format!("host={host}"),
                    &format!("iface={iface_txt}"),
                    "version=1",
                ])
                .spawn()?;
            self.children.push(child);
            log::info!(
                "mDNS: advertising {} on {}:{} (iface={})",
                service_name,
                host,
                port,
                iface_txt
            );
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
