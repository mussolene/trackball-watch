//! Shared helpers for mDNS backends (macOS dns-sd vs Rust mdns-sd).

/// DNS-SD instance names must be safe ASCII for Bonjour CLI on Windows.
pub fn service_instance_name(base: &str, index: usize) -> String {
    format!("{base}-{index:02}")
}

/// Sanitize for TXT / logging: printable ASCII only (Bonjour CLI on Windows is picky).
pub fn sanitize_txt_ascii(s: &str) -> String {
    let t: String = s
        .chars()
        .map(|c| {
            if c == ' ' {
                '_'
            } else if matches!(c, 'a'..='z' | 'A'..='Z' | '0'..='9' | '-' | '_' | '.') {
                c
            } else if c.is_ascii() && !c.is_control() {
                c
            } else {
                '_'
            }
        })
        .collect();
    let t = t.trim_matches('_').trim();
    if t.is_empty() {
        "lan".to_string()
    } else {
        t.chars().take(120).collect()
    }
}
