//! Windows input injection via SendInput API.
//!
//! Does not require administrator privileges.
//! Uses MOUSEEVENTF_MOVE for relative movement and MOUSEEVENTF_WHEEL for scroll.

use crate::injector::platform::{InjectorError, InputInjector};

#[cfg(target_os = "windows")]
mod imp {
    use super::*;
    use windows::Win32::Foundation::POINT;
    use windows::Win32::UI::Input::KeyboardAndMouse::{
        SendInput, INPUT, INPUT_0, INPUT_MOUSE, MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP,
        MOUSEEVENTF_MOVE, MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP, MOUSEEVENTF_WHEEL,
        MOUSEINPUT, MOUSE_EVENT_FLAGS,
    };
    use windows::Win32::UI::WindowsAndMessaging::GetCursorPos;

    pub struct WindowsInjector;

    impl WindowsInjector {
        pub fn new() -> Self {
            Self
        }

        fn send_mouse_input(&self, flags: MOUSE_EVENT_FLAGS, dx: i32, dy: i32, data: i32) {
            let input = INPUT {
                r#type: INPUT_MOUSE,
                Anonymous: INPUT_0 {
                    mi: MOUSEINPUT {
                        dx,
                        dy,
                        mouseData: data as u32,
                        dwFlags: flags,
                        time: 0,
                        dwExtraInfo: 0,
                    },
                },
            };
            unsafe {
                SendInput(&[input], std::mem::size_of::<INPUT>() as i32);
            }
        }
    }

    impl InputInjector for WindowsInjector {
        fn move_relative(&self, dx: f64, dy: f64) -> Result<(), InjectorError> {
            self.send_mouse_input(MOUSEEVENTF_MOVE, dx as i32, dy as i32, 0);
            Ok(())
        }

        fn move_absolute(&self, x: f64, y: f64) -> Result<(), InjectorError> {
            use windows::Win32::UI::Input::KeyboardAndMouse::MOUSEEVENTF_ABSOLUTE;
            // MOUSEEVENTF_ABSOLUTE coordinates are 0..65535 mapped to screen
            // We need to convert pixel coords to the normalized range
            use windows::Win32::UI::WindowsAndMessaging::{
                GetSystemMetrics, SM_CXSCREEN, SM_CYSCREEN,
            };
            let screen_w = unsafe { GetSystemMetrics(SM_CXSCREEN) } as f64;
            let screen_h = unsafe { GetSystemMetrics(SM_CYSCREEN) } as f64;
            let nx = ((x / screen_w) * 65535.0) as i32;
            let ny = ((y / screen_h) * 65535.0) as i32;
            self.send_mouse_input(MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_MOVE, nx, ny, 0);
            Ok(())
        }

        fn left_button_down(&self) -> Result<(), InjectorError> {
            self.send_mouse_input(MOUSEEVENTF_LEFTDOWN, 0, 0, 0);
            Ok(())
        }

        fn left_button_up(&self) -> Result<(), InjectorError> {
            self.send_mouse_input(MOUSEEVENTF_LEFTUP, 0, 0, 0);
            Ok(())
        }

        fn right_click(&self) -> Result<(), InjectorError> {
            self.send_mouse_input(MOUSEEVENTF_RIGHTDOWN, 0, 0, 0);
            self.send_mouse_input(MOUSEEVENTF_RIGHTUP, 0, 0, 0);
            Ok(())
        }

        fn scroll_vertical(&self, lines: f64) -> Result<(), InjectorError> {
            // WHEEL_DELTA = 120 per notch
            let delta = (lines * 120.0) as i32;
            self.send_mouse_input(MOUSEEVENTF_WHEEL, 0, 0, delta);
            Ok(())
        }
    }
}

#[cfg(target_os = "windows")]
pub use imp::WindowsInjector;

#[cfg(test)]
mod tests {
    #[test]
    #[ignore = "requires Windows"]
    fn move_cursor_relative() {
        #[cfg(target_os = "windows")]
        {
            use super::imp::WindowsInjector;
            use crate::injector::platform::InputInjector;
            let injector = WindowsInjector::new();
            injector.move_relative(10.0, 0.0).unwrap();
            injector.move_relative(-10.0, 0.0).unwrap();
        }
    }
}
