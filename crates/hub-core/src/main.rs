//! hub-server entry point: startup order and shutdown. The servers live in
//! hub-http (REST) and hub-grpc (gRPC).

mod cli;
mod config;
mod logging;
mod partitions;

use std::net::{IpAddr, Ipv4Addr, SocketAddr};

use hub_cache::Cache;
use hub_db::Database;
use loxide::{log_error, log_info};

const HOST: IpAddr = IpAddr::V4(Ipv4Addr::LOCALHOST);

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Load .env before reading any environment variable. Existing variables
    // are never overwritten.
    let dotenv = dotenvy::dotenv();

    let args = match cli::parse(std::env::args().skip(1)) {
        Ok(Some(args)) => args,
        Ok(None) => {
            println!("{}", cli::USAGE);
            return Ok(());
        }
        Err(msg) => cli::usage_error(&msg),
    };
    let settings = match config::resolve(&args, |key| std::env::var(key).ok()) {
        Ok(settings) => settings,
        Err(msg) => cli::usage_error(&msg),
    };

    let logger = logging::init();
    log_info!(logger, "starting hub-server", "version" => env!("CARGO_PKG_VERSION"));
    if let Err(err) = &dotenv
        && !err.not_found()
    {
        log_error!(logger, "could not load .env", "error" => err.to_string());
    }

    // Postgres: connect both pools, then refuse unsafe role setups.
    let db = Database::connect(&settings.database_url, &settings.database_platform_url)
        .await
        .inspect_err(|err| {
            log_error!(logger, "cannot connect to PostgreSQL", "error" => err.to_string());
        })?;
    let roles = db.verify_roles().await.inspect_err(|err| {
        log_error!(logger, "database role check failed", "error" => err.to_string());
    })?;
    let pg = db.server_info().await.inspect_err(|err| {
        log_error!(logger, "cannot query PostgreSQL", "error" => err.to_string());
    })?;
    log_info!(logger, "connected to PostgreSQL",
        "database" => pg.database,
        "server_version" => pg.version,
        "server_time" => pg.server_time,
        "app_role" => roles.app,
        "platform_role" => roles.platform
    );

    // Audit log partitions: create any missing ones now, then re-check daily.
    partitions::ensure(&db, &logger).await.inspect_err(|err| {
        log_error!(logger, "cannot create audit log partitions (are migrations applied? run `make migrate`)",
            "error" => err.to_string());
    })?;
    let partition_job = partitions::spawn_daily(db.clone(), logger.clone());

    // Redis
    let cache = Cache::connect(&settings.redis_url)
        .await
        .inspect_err(|err| {
            log_error!(logger, "cannot connect to Redis", "error" => err.to_string());
        })?;
    let redis_version = cache.server_version().await.inspect_err(|err| {
        log_error!(logger, "cannot query Redis", "error" => err.to_string());
    })?;
    log_info!(logger, "connected to Redis", "redis_version" => redis_version);

    // Bind both ports before serving anything, so a port that is already in
    // use stops startup with a clear error.
    let rest_addr = SocketAddr::new(HOST, settings.rest_port);
    let grpc_addr = SocketAddr::new(HOST, settings.grpc_port);
    let grpc_listener = hub_grpc::bind(grpc_addr).inspect_err(|err| {
        log_error!(logger, "cannot bind gRPC port", "addr" => grpc_addr.to_string(), "error" => err.to_string());
    })?;
    let rest_listener = hub_http::bind(rest_addr).inspect_err(|err| {
        log_error!(logger, "cannot bind REST port", "addr" => rest_addr.to_string(), "error" => err.to_string());
    })?;

    let rest = hub_http::start(rest_listener);
    log_info!(logger, "REST server listening", "addr" => rest_addr.to_string());
    let grpc = hub_grpc::start(grpc_listener);
    log_info!(logger, "gRPC server listening", "addr" => grpc_addr.to_string());

    tokio::signal::ctrl_c().await?;
    log_info!(logger, "shutdown signal received, stopping servers");

    // Drain both servers at the same time.
    let (rest_result, grpc_result) = tokio::join!(rest.stop(), grpc.stop());
    if let Err(err) = rest_result {
        log_error!(logger, "REST server error", "error" => err.to_string());
    }
    if let Err(err) = grpc_result {
        log_error!(logger, "gRPC server error", "error" => err.to_string());
    }
    partition_job.abort();
    db.close().await;

    log_info!(logger, "hub-server stopped");
    Ok(())
}
