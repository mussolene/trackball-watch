//! End-to-end latency tester for TBP.
//!
//! Sends PING packets to the desktop host and measures round-trip time.
//!
//! Usage:
//!   latency-tester --host 192.168.1.5 --port 47474 --count 100
//!
//! Output:
//!   Sent 100 pings to 192.168.1.5:47474
//!   RTT p50: 8.2ms  p95: 14.1ms  p99: 22.4ms  max: 31.0ms

use std::net::SocketAddr;
use std::time::{Duration, Instant};
use tokio::net::UdpSocket;

const PING_TYPE: u8 = 0x20;
const PONG_TYPE: u8 = 0x21;
const TIMEOUT: Duration = Duration::from_millis(500);

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let host = get_arg(&args, "--host").unwrap_or_else(|| "127.0.0.1".to_string());
    let port: u16 = get_arg(&args, "--port")
        .and_then(|s| s.parse().ok())
        .unwrap_or(47474);
    let count: usize = get_arg(&args, "--count")
        .and_then(|s| s.parse().ok())
        .unwrap_or(100);

    let target: SocketAddr = format!("{}:{}", host, port).parse()?;
    let socket = UdpSocket::bind("0.0.0.0:0").await?;

    println!("Sending {} PINGs to {}…", count, target);

    let mut rtts: Vec<f64> = Vec::with_capacity(count);
    let mut timeouts = 0usize;

    for seq in 0u16..(count as u16) {
        let packet = build_ping(seq);
        let sent_at = Instant::now();
        socket.send_to(&packet, target).await?;

        let mut buf = [0u8; 64];
        match tokio::time::timeout(TIMEOUT, socket.recv_from(&mut buf)).await {
            Ok(Ok((len, _))) => {
                let elapsed_ms = sent_at.elapsed().as_secs_f64() * 1000.0;
                if len >= 1 && buf[2] == PONG_TYPE {
                    rtts.push(elapsed_ms);
                }
            }
            Ok(Err(e)) => eprintln!("recv error: {}", e),
            Err(_) => {
                timeouts += 1;
            }
        }

        // Small gap between pings
        tokio::time::sleep(Duration::from_millis(10)).await;
    }

    if rtts.is_empty() {
        println!("No responses received ({} timeouts)", timeouts);
        return Ok(());
    }

    rtts.sort_by(|a, b| a.partial_cmp(b).unwrap());

    let p50 = percentile(&rtts, 50.0);
    let p95 = percentile(&rtts, 95.0);
    let p99 = percentile(&rtts, 99.0);
    let max = rtts.last().copied().unwrap_or(0.0);
    let mean = rtts.iter().sum::<f64>() / rtts.len() as f64;

    println!("Results ({} responses, {} timeouts):", rtts.len(), timeouts);
    println!("  mean: {:.1}ms", mean);
    println!("  p50:  {:.1}ms", p50);
    println!("  p95:  {:.1}ms", p95);
    println!("  p99:  {:.1}ms", p99);
    println!("  max:  {:.1}ms", max);

    // Phase 1 targets
    let p50_target = 15.0;
    let p99_target = 30.0;
    println!();
    if p50 <= p50_target && p99 <= p99_target {
        println!("✓ PASS: p50={:.1}ms ≤ {}ms, p99={:.1}ms ≤ {}ms", p50, p50_target, p99, p99_target);
    } else {
        println!("✗ FAIL: targets p50≤{}ms, p99≤{}ms", p50_target, p99_target);
        std::process::exit(1);
    }

    Ok(())
}

/// Build an 8-byte PING packet: [seq:u16 LE][0x20][0x00][timestamp_us:u32 LE]
fn build_ping(seq: u16) -> Vec<u8> {
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .subsec_micros();
    let mut packet = Vec::with_capacity(8);
    packet.extend_from_slice(&seq.to_le_bytes());
    packet.push(PING_TYPE);
    packet.push(0); // flags
    packet.extend_from_slice(&ts.to_le_bytes());
    packet
}

fn percentile(sorted: &[f64], pct: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    let idx = ((pct / 100.0) * (sorted.len() - 1) as f64).round() as usize;
    sorted[idx.min(sorted.len() - 1)]
}

fn get_arg(args: &[String], flag: &str) -> Option<String> {
    args.windows(2)
        .find(|w| w[0] == flag)
        .map(|w| w[1].clone())
}
