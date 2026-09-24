//! Redis access for Hub. Redis holds transient state only; Postgres is the
//! source of truth.

use redis::aio::ConnectionManager;

#[derive(Debug, thiserror::Error)]
#[error(transparent)]
pub struct CacheError(#[from] redis::RedisError);

/// A cheaply cloneable Redis handle. The connection manager reconnects on its
/// own if Redis restarts.
#[derive(Clone)]
pub struct Cache {
    conn: ConnectionManager,
}

impl Cache {
    /// Connects and verifies the connection with a `PING`.
    pub async fn connect(url: &str) -> Result<Self, CacheError> {
        let client = redis::Client::open(url)?;
        let conn = ConnectionManager::new(client).await?;
        let cache = Self { conn };
        cache.ping().await?;
        Ok(cache)
    }

    pub async fn ping(&self) -> Result<(), CacheError> {
        let mut conn = self.conn.clone();
        let _: String = redis::cmd("PING").query_async(&mut conn).await?;
        Ok(())
    }

    /// The `redis_version` reported by the live server (`INFO server`).
    pub async fn server_version(&self) -> Result<String, CacheError> {
        let mut conn = self.conn.clone();
        let info: String = redis::cmd("INFO")
            .arg("server")
            .query_async(&mut conn)
            .await?;
        Ok(info
            .lines()
            .find_map(|line| line.strip_prefix("redis_version:"))
            .unwrap_or("unknown")
            .trim()
            .to_owned())
    }

    pub fn connection(&self) -> ConnectionManager {
        self.conn.clone()
    }
}
