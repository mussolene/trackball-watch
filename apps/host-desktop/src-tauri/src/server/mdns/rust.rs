//! mDNS via pure-Rust [`mdns-sd`] multicast (Windows / Linux). Does not depend on
//! Apple Bonjour Service or `dns-sd.exe`, so iPhone can discover the desktop when
//! the OS firewall allows UDP 5353 (mDNS) and 47474 (TBP).

use super::common::{sanitize_txt_ascii, service_instance_name};
use mdns_sd::{ServiceDaemon, ServiceInfo};
use std::io;

fn map_mdns_err(e: mdns_sd::Error) -> io::Error {
    io::Error::new(io::ErrorKind::Other, format!("{e}"))
}

fn host_fqdn() -> String {
    let raw = hostname::get()
        .ok()
        .and_then(|h| h.into_string().ok())
        .unwrap_or_else(|| "trackball".to_string());
    let safe: String = raw
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' {
                c
            } else {
                '-'
            }
        })
        .take(63)
        .collect();
    let safe = if safe.is_empty() {
        "trackball".to_string()
    } else {
        safe
    };
    format!("{safe}.local.")
}

/// mDNS advertiser using multicast DNS-SD (no Apple `dns-sd` subprocess).
pub struct MdnsAdvertiser {
    daemon: ServiceDaemon,
}

impl MdnsAdvertiser {
    pub fn new() -> Result<Self, io::Error> {
        let daemon = ServiceDaemon::new().map_err(map_mdns_err)?;
        Ok(Self { daemon })
    }

    /// Advertise `_tbp._udp.local.` on `port` for each LAN interface host.
    pub fn advertise_many(
        &mut self,
        port: u16,
        device_id: &str,
        hosts: &[(String, String)],
    ) -> Result<(), io::Error> {
        let instance_base = format!("TrackBall-{}", &device_id[..8.min(device_id.len())]);
        let fqdn = host_fqdn();

        if hosts.is_empty() {
            log::warn!(
                "mDNS: no RFC1918 LAN addresses; skipping advertisement (iPhone may need manual IP)"
            );
            return Ok(());
        }

        for (index, (host, iface)) in hosts.iter().enumerate() {
            let instance = service_instance_name(&instance_base, index);
            let iface_txt = sanitize_txt_ascii(iface);
            log::debug!("mDNS iface raw (index {index}): {iface}");

            let props: Vec<(&str, String)> = vec![
                ("device_id", device_id.to_string()),
                ("port", port.to_string()),
                ("host", host.clone()),
                ("iface", iface_txt.clone()),
                ("version", "1".to_string()),
            ];

            let info = ServiceInfo::new(
                "_tbp._udp.local.",
                &instance,
                &fqdn,
                host.as_str(),
                port,
                props.as_slice(),
            )
            .map_err(map_mdns_err)?;

            self.daemon.register(info).map_err(map_mdns_err)?;
            log::info!(
                "mDNS (multicast): registered {} → {}:{} (iface={})",
                instance,
                host,
                port,
                iface_txt
            );
        }
        Ok(())
    }

    pub fn stop(&mut self) {
        let _ = self.daemon.shutdown();
    }
}

impl Drop for MdnsAdvertiser {
    fn drop(&mut self) {
        self.stop();
    }
}
