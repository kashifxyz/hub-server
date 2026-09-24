//! Keeps monthly `audit_logs` partitions created ahead of time, so they never
//! need to be created by hand.

use std::time::Duration;

use hub_db::{Database, DbError};
use loxide::{Logger, log_error, log_info};
use tokio::task::JoinHandle;
use tokio::time::{MissedTickBehavior, interval};

/// Partitions exist for the current month plus this many months ahead.
const MONTHS_AHEAD: i32 = 3;

/// How often the background job re-checks.
const CHECK_EVERY: Duration = Duration::from_secs(24 * 60 * 60);

/// Creates any missing partitions now. Called once at startup; an error here
/// stops startup (for example when migrations haven't been applied).
pub async fn ensure(db: &Database, logger: &Logger) -> Result<(), DbError> {
    let created = db.ensure_audit_partitions(MONTHS_AHEAD).await?;
    log_info!(logger, "audit log partitions ready",
        "months_ahead" => MONTHS_AHEAD,
        "created" => created
    );
    Ok(())
}

/// Re-checks daily for as long as the server runs. Failures are logged and
/// retried on the next run; the DEFAULT partition keeps inserts working in the
/// meantime.
pub fn spawn_daily(db: Database, logger: Logger) -> JoinHandle<()> {
    tokio::spawn(async move {
        let mut ticker = interval(CHECK_EVERY);
        ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);
        // The first tick completes immediately; startup already ran `ensure`.
        ticker.tick().await;

        loop {
            ticker.tick().await;
            match db.ensure_audit_partitions(MONTHS_AHEAD).await {
                Ok(created) if created > 0 => {
                    log_info!(logger, "created audit log partitions", "created" => created);
                }
                Ok(_) => {}
                Err(err) => {
                    log_error!(logger, "could not create audit log partitions", "error" => err.to_string());
                }
            }
        }
    })
}
