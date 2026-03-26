pub mod platform;

#[cfg(target_os = "macos")]
pub mod macos;

#[cfg(target_os = "windows")]
pub mod windows;

#[cfg(target_os = "linux")]
pub mod linux;

use platform::{InjectorError, InputInjector};
use std::sync::Arc;

/// Create the platform-appropriate input injector.
pub fn create_injector() -> Result<Arc<dyn InputInjector>, InjectorError> {
    #[cfg(target_os = "macos")]
    {
        Ok(Arc::new(macos::MacOSInjector::new()?))
    }
    #[cfg(target_os = "windows")]
    {
        Ok(Arc::new(windows::WindowsInjector::new()))
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    {
        Err(InjectorError::Platform("unsupported platform".to_string()))
    }
}
