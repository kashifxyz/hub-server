//! PostgreSQL access for Hub.
//!
//! The server opens two pools, one per database role:
//!
//! * `app` connects as `hubappusr`: not the table owner, no `BYPASSRLS`, so
//!   Row-Level Security applies. All request handling uses it.
//! * `platform` connects as `hubplatformusr`, which has `BYPASSRLS`. Only for
//!   platform administration and background jobs.
//!
//! The third role, `hubownerusr`, owns the schema and runs migrations. The
//! server never connects as it.

use std::time::Duration;

use sqlx::postgres::{PgPool, PgPoolOptions};

const MAX_CONNECTIONS: u32 = 10;
const ACQUIRE_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Debug, thiserror::Error)]
pub enum DbError {
    #[error(transparent)]
    Sqlx(#[from] sqlx::Error),

    #[error("unsafe database role configuration: {0}")]
    UnsafeRole(String),
}

#[derive(Clone)]
pub struct Database {
    app: PgPool,
    platform: PgPool,
}

/// The database roles the two pools are connected as.
#[derive(Debug, Clone)]
pub struct ConnectedRoles {
    pub app: String,
    pub platform: String,
}

/// What the connected PostgreSQL server reports about itself.
#[derive(Debug, Clone)]
pub struct ServerInfo {
    /// `server_version`, for example `18.4`.
    pub version: String,
    /// The database the pools are connected to.
    pub database: String,
    /// The server's current time (UTC, RFC 3339).
    pub server_time: String,
}

impl Database {
    /// Opens both pools. Each pool opens a connection immediately, so an
    /// unreachable database or bad credentials fail here.
    pub async fn connect(app_url: &str, platform_url: &str) -> Result<Self, DbError> {
        let app = pool(app_url).await?;
        let platform = pool(platform_url).await?;
        Ok(Self { app, platform })
    }

    /// Refuses role setups that would silently defeat Row-Level Security:
    /// the app role must not be a superuser or have `BYPASSRLS`, the platform
    /// role must have `BYPASSRLS`, and the two must be different roles.
    pub async fn verify_roles(&self) -> Result<ConnectedRoles, DbError> {
        let app = role_attributes(&self.app).await?;
        if app.superuser || app.bypass_rls {
            return Err(DbError::UnsafeRole(format!(
                "the app role `{}` must not be a superuser or have BYPASSRLS",
                app.name
            )));
        }

        let platform = role_attributes(&self.platform).await?;
        if !platform.bypass_rls {
            return Err(DbError::UnsafeRole(format!(
                "the platform role `{}` must have BYPASSRLS",
                platform.name
            )));
        }
        if platform.name == app.name {
            return Err(DbError::UnsafeRole(
                "the app and platform pools must use different roles".into(),
            ));
        }

        Ok(ConnectedRoles {
            app: app.name,
            platform: platform.name,
        })
    }

    /// Facts reported by the live server through the app pool, for the
    /// startup log.
    pub async fn server_info(&self) -> Result<ServerInfo, DbError> {
        let (version, database, server_time): (String, String, String) = sqlx::query_as(
            "SELECT current_setting('server_version'), current_database(), \
             to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"')",
        )
        .fetch_one(&self.app)
        .await?;
        Ok(ServerInfo {
            version,
            database,
            server_time,
        })
    }

    /// Pool for request handling (`hubappusr`, RLS enforced).
    pub fn app(&self) -> &PgPool {
        &self.app
    }

    /// RLS-bypassing pool (`hubplatformusr`). Platform admin and jobs only.
    pub fn platform(&self) -> &PgPool {
        &self.platform
    }

    pub async fn close(&self) {
        self.app.close().await;
        self.platform.close().await;
    }
}

async fn pool(url: &str) -> Result<PgPool, DbError> {
    let pool = PgPoolOptions::new()
        .max_connections(MAX_CONNECTIONS)
        .acquire_timeout(ACQUIRE_TIMEOUT)
        .connect(url)
        .await?;
    Ok(pool)
}

struct RoleAttributes {
    name: String,
    superuser: bool,
    bypass_rls: bool,
}

async fn role_attributes(pool: &PgPool) -> Result<RoleAttributes, DbError> {
    let (name, superuser, bypass_rls): (String, bool, bool) = sqlx::query_as(
        "SELECT rolname::text, rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user",
    )
    .fetch_one(pool)
    .await?;
    Ok(RoleAttributes {
        name,
        superuser,
        bypass_rls,
    })
}
