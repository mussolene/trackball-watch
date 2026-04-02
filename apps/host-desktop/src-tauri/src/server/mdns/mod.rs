//! mDNS advertisement for `_tbp._udp.local.`
//!
//! - **macOS:** `dns-sd -R` subprocess → system mDNSResponder (required so iPhone
//!   Bonjour sees the host; pure-Rust multicast does not integrate with Apple’s stack).
//! - **Windows / Linux:** [`mdns-sd`] multicast in-process — no Apple Bonjour Service.

mod common;

#[cfg(target_os = "macos")]
mod macos;
#[cfg(not(target_os = "macos"))]
mod rust;

#[cfg(target_os = "macos")]
pub use macos::MdnsAdvertiser;
#[cfg(not(target_os = "macos"))]
pub use rust::MdnsAdvertiser;
