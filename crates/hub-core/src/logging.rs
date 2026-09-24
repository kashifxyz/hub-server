//! Logger setup (loxide).

use loxide::{Config, Format, Logger};

/// Creates the application logger. `LOG_LEVEL` is read from the environment;
/// output is always pretty.
pub fn init() -> Logger {
    Logger::new(Config::from_env().with_format(Format::Pretty))
}
