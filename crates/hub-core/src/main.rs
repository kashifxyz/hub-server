use std::net::{IpAddr, Ipv4Addr, SocketAddr};

use actix_web::{App, HttpServer};
use loxide::{Config, Format, Logger, log_error, log_info};
use tokio::sync::oneshot;
use tonic::transport::server::TcpIncoming;

const HOST: IpAddr = IpAddr::V4(Ipv4Addr::LOCALHOST);
const DEFAULT_REST_PORT: u16 = 8443;
const DEFAULT_GRPC_PORT: u16 = 50053;

const USAGE: &str = "\
Usage: hub-server [OPTIONS]

Options:
  --rest-port <PORT>  REST (Actix Web) port [default: 8443] (alias: --restport)
  --grpc-port <PORT>  gRPC (tonic) port [default: 50053]
  -h, --help          Print this help";

#[derive(Debug, PartialEq, Eq)]
struct Args {
    rest_port: u16,
    grpc_port: u16,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args = match parse_args(std::env::args().skip(1)) {
        Ok(Some(args)) => args,
        Ok(None) => {
            println!("{USAGE}");
            return Ok(());
        }
        Err(msg) => {
            eprintln!("error: {msg}\n\n{USAGE}");
            std::process::exit(2);
        }
    };

    // LOG_LEVEL is read from the environment; output is always pretty.
    let logger = Logger::new(Config::from_env().with_format(Format::Pretty));

    let http_addr = SocketAddr::new(HOST, args.rest_port);
    let grpc_addr = SocketAddr::new(HOST, args.grpc_port);

    log_info!(logger, "starting hub-server", "version" => env!("CARGO_PKG_VERSION"));

    // Bind both ports before serving anything, so a port that is already in
    // use stops startup with a clear error.
    let grpc_incoming = TcpIncoming::bind(grpc_addr).inspect_err(|err| {
        log_error!(logger, "cannot bind gRPC port", "addr" => grpc_addr.to_string(), "error" => err.to_string());
    })?;
    let http_server = HttpServer::new(App::new)
        .bind(http_addr)
        .inspect_err(|err| {
            log_error!(logger, "cannot bind REST port", "addr" => http_addr.to_string(), "error" => err.to_string());
        })?
        .disable_signals()
        .run();

    // REST (Actix Web)
    let http_handle = http_server.handle();
    let http_task = tokio::spawn(http_server);
    log_info!(logger, "REST server listening", "addr" => http_addr.to_string());

    // gRPC (tonic)
    let (_health_reporter, health_service) = tonic_health::server::health_reporter();
    let (grpc_stop_tx, grpc_stop_rx) = oneshot::channel::<()>();
    let grpc_task = tokio::spawn(
        tonic::transport::Server::builder()
            .add_service(health_service)
            .serve_with_incoming_shutdown(grpc_incoming, async {
                let _ = grpc_stop_rx.await;
            }),
    );
    log_info!(logger, "gRPC server listening", "addr" => grpc_addr.to_string());

    tokio::signal::ctrl_c().await?;
    log_info!(logger, "shutdown signal received, stopping servers");

    let _ = grpc_stop_tx.send(());
    http_handle.stop(true).await;

    if let Ok(Err(err)) = http_task.await {
        log_error!(logger, "REST server error", "error" => err.to_string());
    }
    if let Ok(Err(err)) = grpc_task.await {
        log_error!(logger, "gRPC server error", "error" => err.to_string());
    }

    log_info!(logger, "hub-server stopped");
    Ok(())
}

/// Parses command-line flags. Accepts `--flag=value` and `--flag value`.
/// Returns `Ok(None)` when help was requested.
fn parse_args(args: impl IntoIterator<Item = String>) -> Result<Option<Args>, String> {
    let mut parsed = Args {
        rest_port: DEFAULT_REST_PORT,
        grpc_port: DEFAULT_GRPC_PORT,
    };
    let mut args = args.into_iter();

    while let Some(arg) = args.next() {
        let (flag, inline_value) = match arg.split_once('=') {
            Some((flag, value)) => (flag.to_owned(), Some(value.to_owned())),
            None => (arg, None),
        };

        let target = match flag.as_str() {
            "-h" | "--help" => return Ok(None),
            "--rest-port" | "--restport" => &mut parsed.rest_port,
            "--grpc-port" => &mut parsed.grpc_port,
            other => return Err(format!("unknown option `{other}`")),
        };

        let value = match inline_value {
            Some(value) => value,
            None => args
                .next()
                .ok_or_else(|| format!("`{flag}` requires a port number"))?,
        };
        *target = parse_port(&flag, &value)?;
    }

    if parsed.rest_port == parsed.grpc_port {
        return Err(format!(
            "REST and gRPC cannot share port {}",
            parsed.rest_port
        ));
    }
    Ok(Some(parsed))
}

fn parse_port(flag: &str, value: &str) -> Result<u16, String> {
    match value.parse::<u16>() {
        Ok(0) | Err(_) => Err(format!(
            "invalid port `{value}` for `{flag}` (expected 1-65535)"
        )),
        Ok(port) => Ok(port),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(args: &[&str]) -> Result<Option<Args>, String> {
        parse_args(args.iter().map(|a| (*a).to_owned()))
    }

    #[test]
    fn defaults_when_no_flags() {
        assert_eq!(
            parse(&[]),
            Ok(Some(Args {
                rest_port: 8443,
                grpc_port: 50053
            }))
        );
    }

    #[test]
    fn accepts_equals_and_space_forms() {
        let expected = Ok(Some(Args {
            rest_port: 9000,
            grpc_port: 9001,
        }));
        assert_eq!(parse(&["--rest-port=9000", "--grpc-port=9001"]), expected);
        assert_eq!(
            parse(&["--rest-port", "9000", "--grpc-port", "9001"]),
            expected
        );
        assert_eq!(parse(&["--restport=9000", "--grpc-port=9001"]), expected);
    }

    #[test]
    fn help_returns_none() {
        assert_eq!(parse(&["--help"]), Ok(None));
    }

    #[test]
    fn rejects_bad_input() {
        assert!(parse(&["--rest-port=0"]).is_err());
        assert!(parse(&["--rest-port=70000"]).is_err());
        assert!(parse(&["--grpc-port"]).is_err());
        assert!(parse(&["--port=1"]).is_err());
        assert!(parse(&["--rest-port=9000", "--grpc-port=9000"]).is_err());
    }
}
