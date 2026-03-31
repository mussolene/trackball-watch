use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

const TRACE_PATH: &str = "/tmp/trackball-host-motion.log";

fn trace_lock() -> &'static Mutex<()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
}

pub fn path() -> PathBuf {
    PathBuf::from(TRACE_PATH)
}

pub fn reset() {
    let _guard = trace_lock().lock().ok();
    let _ = fs::write(path(), b"");
}

pub fn append_line(message: impl AsRef<str>) {
    let _guard = match trace_lock().lock() {
        Ok(guard) => guard,
        Err(_) => return,
    };
    let mut file = match OpenOptions::new()
        .create(true)
        .append(true)
        .open(path())
    {
        Ok(file) => file,
        Err(_) => return,
    };
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let _ = writeln!(file, "[{}] {}", ts, message.as_ref());
}
