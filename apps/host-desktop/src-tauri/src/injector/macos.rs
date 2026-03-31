//! macOS input injection via CGEvent.
//!
//! Requires Accessibility permission: System Settings → Privacy & Security
//! → Accessibility → enable TrackBall Watch.

use crate::injector::platform::{InjectorError, InputInjector};

#[cfg(target_os = "macos")]
mod imp {
    use super::*;
    use core_foundation::boolean::CFBoolean;
    use core_foundation::dictionary::CFDictionary;
    use core_foundation::string::CFString;
    use core_foundation::base::TCFType;
    use std::ffi::c_void;

    type CGEventRef = *mut c_void;
    type CGEventSourceRef = *mut c_void;
    type CGFloat = f64;

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct CGPoint {
        x: CGFloat,
        y: CGFloat,
    }

    // CGEventType constants
    const K_CGEVENT_MOUSE_MOVED: u32 = 5;
    const K_CGEVENT_LEFT_MOUSE_DOWN: u32 = 1;
    const K_CGEVENT_LEFT_MOUSE_UP: u32 = 2;
    const K_CGEVENT_RIGHT_MOUSE_DOWN: u32 = 3;
    const K_CGEVENT_RIGHT_MOUSE_UP: u32 = 4;

    // CGMouseButton constants
    const K_CGMOUSE_BUTTON_LEFT: u32 = 0;
    const K_CGMOUSE_BUTTON_RIGHT: u32 = 1;
    const K_CGMOUSE_EVENT_CLICK_STATE: u32 = 1;

    // kCGHIDEventTap = 0
    const K_CGHIDEVENT_TAP: u32 = 0;
    // kCGScrollEventUnitLine = 1
    const K_CGSCROLL_EVENT_UNIT_LINE: u32 = 1;

    #[link(name = "CoreGraphics", kind = "framework")]
    extern "C" {
        fn CGEventCreate(source: CGEventSourceRef) -> CGEventRef;
        fn CGEventCreateMouseEvent(
            source: CGEventSourceRef,
            mouse_type: u32,
            mouse_cursor_position: CGPoint,
            mouse_button: u32,
        ) -> CGEventRef;
        fn CGEventCreateScrollWheelEvent2(
            source: CGEventSourceRef,
            units: u32,
            wheel_count: u32,
            wheel1: i32,
            wheel2: i32,
            wheel3: i32,
        ) -> CGEventRef;
        fn CGEventPost(tap: u32, event: CGEventRef);
        fn CGEventSetIntegerValueField(event: CGEventRef, field: u32, value: i64);
        fn CFRelease(cf: CGEventRef);
        fn CGEventGetLocation(event: CGEventRef) -> CGPoint;
    }

    #[link(name = "ApplicationServices", kind = "framework")]
    extern "C" {
        fn AXIsProcessTrustedWithOptions(options: *const c_void) -> bool;
    }

    /// Get current mouse position using a null event.
    fn current_mouse_position() -> (f64, f64) {
        unsafe {
            let event = CGEventCreate(std::ptr::null_mut());
            if event.is_null() {
                return (0.0, 0.0);
            }
            let pos = CGEventGetLocation(event);
            CFRelease(event);
            (pos.x, pos.y)
        }
    }

    pub struct MacOSInjector;

    impl MacOSInjector {
        pub fn new() -> Result<Self, InjectorError> {
            if !Self::has_accessibility_permission() {
                return Err(InjectorError::PermissionDenied);
            }
            Ok(Self)
        }

        pub fn has_accessibility_permission() -> bool {
            unsafe { AXIsProcessTrustedWithOptions(std::ptr::null()) }
        }

        /// Triggers the **system** Accessibility prompt (same mechanism as many Mac apps):
        /// `AXIsProcessTrustedWithOptions` with `AXTrustedCheckOptionPrompt` = true.
        /// No-op if already trusted. Safe to call every launch; macOS may not re-show the sheet if dismissed recently.
        pub fn prompt_accessibility_permission() -> bool {
            if Self::has_accessibility_permission() {
                return true;
            }
            let key = CFString::new("AXTrustedCheckOptionPrompt");
            let opts = CFDictionary::from_CFType_pairs(&[(key, CFBoolean::true_value())]);
            unsafe {
                AXIsProcessTrustedWithOptions(opts.as_concrete_TypeRef().cast::<c_void>())
            }
        }

        /// Open System Settings → Privacy & Security → Accessibility.
        pub fn open_accessibility_settings() {
            let _ = std::process::Command::new("open")
                .arg("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                .spawn();
        }

        fn post_mouse_event(&self, event_type: u32, x: f64, y: f64, button: u32) {
            unsafe {
                let event = CGEventCreateMouseEvent(
                    std::ptr::null_mut(),
                    event_type,
                    CGPoint { x, y },
                    button,
                );
                if !event.is_null() {
                    CGEventPost(K_CGHIDEVENT_TAP, event);
                    CFRelease(event);
                }
            }
        }

        fn post_click_event(&self, event_type: u32, button: u32, click_state: i64) {
            let (x, y) = current_mouse_position();
            unsafe {
                let event = CGEventCreateMouseEvent(
                    std::ptr::null_mut(),
                    event_type,
                    CGPoint { x, y },
                    button,
                );
                if !event.is_null() {
                    CGEventSetIntegerValueField(event, K_CGMOUSE_EVENT_CLICK_STATE, click_state);
                    CGEventPost(K_CGHIDEVENT_TAP, event);
                    CFRelease(event);
                }
            }
        }
    }

    impl InputInjector for MacOSInjector {
        /// `dx`/`dy` may be fractional; `CGEvent` uses `CGFloat` (sub-point positioning).
        fn move_relative(&self, dx: f64, dy: f64) -> Result<(), InjectorError> {
            let (cx, cy) = current_mouse_position();
            self.post_mouse_event(
                K_CGEVENT_MOUSE_MOVED,
                cx + dx,
                cy + dy,
                K_CGMOUSE_BUTTON_LEFT,
            );
            Ok(())
        }

        fn move_absolute(&self, x: f64, y: f64) -> Result<(), InjectorError> {
            self.post_mouse_event(K_CGEVENT_MOUSE_MOVED, x, y, K_CGMOUSE_BUTTON_LEFT);
            Ok(())
        }

        fn left_click(&self) -> Result<(), InjectorError> {
            let (x, y) = current_mouse_position();
            self.post_mouse_event(K_CGEVENT_LEFT_MOUSE_DOWN, x, y, K_CGMOUSE_BUTTON_LEFT);
            self.post_mouse_event(K_CGEVENT_LEFT_MOUSE_UP, x, y, K_CGMOUSE_BUTTON_LEFT);
            Ok(())
        }

        fn double_click(&self) -> Result<(), InjectorError> {
            self.post_click_event(K_CGEVENT_LEFT_MOUSE_DOWN, K_CGMOUSE_BUTTON_LEFT, 1);
            self.post_click_event(K_CGEVENT_LEFT_MOUSE_UP, K_CGMOUSE_BUTTON_LEFT, 1);
            self.post_click_event(K_CGEVENT_LEFT_MOUSE_DOWN, K_CGMOUSE_BUTTON_LEFT, 2);
            self.post_click_event(K_CGEVENT_LEFT_MOUSE_UP, K_CGMOUSE_BUTTON_LEFT, 2);
            Ok(())
        }

        fn right_click(&self) -> Result<(), InjectorError> {
            let (x, y) = current_mouse_position();
            self.post_mouse_event(K_CGEVENT_RIGHT_MOUSE_DOWN, x, y, K_CGMOUSE_BUTTON_RIGHT);
            self.post_mouse_event(K_CGEVENT_RIGHT_MOUSE_UP, x, y, K_CGMOUSE_BUTTON_RIGHT);
            Ok(())
        }

        fn scroll_vertical(&self, lines: f64) -> Result<(), InjectorError> {
            unsafe {
                let event = CGEventCreateScrollWheelEvent2(
                    std::ptr::null_mut(),
                    K_CGSCROLL_EVENT_UNIT_LINE,
                    1,
                    -(lines as i32),
                    0,
                    0,
                );
                if !event.is_null() {
                    CGEventPost(K_CGHIDEVENT_TAP, event);
                    CFRelease(event);
                }
            }
            Ok(())
        }
    }
}

#[cfg(target_os = "macos")]
pub use imp::MacOSInjector;

#[cfg(test)]
mod tests {
    #[test]
    #[ignore = "requires macOS with Accessibility permission"]
    fn move_cursor_in_circle() {
        #[cfg(target_os = "macos")]
        {
            use super::imp::MacOSInjector;
            use crate::injector::platform::InputInjector;
            use std::f64::consts::PI;

            let injector = MacOSInjector::new().expect("Accessibility permission required");
            let steps = 36;
            let radius = 100.0_f64;
            let center_x = 500.0_f64;
            let center_y = 400.0_f64;

            for i in 0..=steps {
                let angle = 2.0 * PI * (i as f64) / (steps as f64);
                let x = center_x + radius * angle.cos();
                let y = center_y + radius * angle.sin();
                injector.move_absolute(x, y).unwrap();
                std::thread::sleep(std::time::Duration::from_millis(16));
            }
        }
    }
}
