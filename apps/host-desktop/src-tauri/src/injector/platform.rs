//! Platform-agnostic input injector trait.

/// Errors from input injection.
#[derive(Debug, thiserror::Error)]
pub enum InjectorError {
    #[error("permission denied — accessibility access required")]
    PermissionDenied,
    #[error("platform error: {0}")]
    Platform(String),
}

/// Platform-independent interface for injecting mouse input.
pub trait InputInjector: Send + Sync {
    /// Move cursor by a relative delta (pixels).
    fn move_relative(&self, dx: f64, dy: f64) -> Result<(), InjectorError>;

    /// Move cursor to an absolute position.
    fn move_absolute(&self, x: f64, y: f64) -> Result<(), InjectorError>;

    /// Press and hold the left mouse button.
    fn left_button_down(&self) -> Result<(), InjectorError>;

    /// Release the held left mouse button.
    fn left_button_up(&self) -> Result<(), InjectorError>;

    /// Perform a left click.
    fn left_click(&self) -> Result<(), InjectorError> {
        self.left_button_down()?;
        self.left_button_up()
    }

    /// Perform a system-recognized double click.
    fn double_click(&self) -> Result<(), InjectorError> {
        self.left_click()?;
        self.left_click()
    }

    /// Perform a right click.
    fn right_click(&self) -> Result<(), InjectorError>;

    /// Scroll vertically by `lines` (positive = down).
    fn scroll_vertical(&self, lines: f64) -> Result<(), InjectorError>;

    /// Current cursor position in screen pixels (top-left origin, same space as `move_absolute`).
    fn cursor_position(&self) -> Result<(f64, f64), InjectorError>;
}
