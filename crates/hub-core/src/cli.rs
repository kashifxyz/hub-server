//! Command-line flags. Every flag is optional and overrides the matching
//! environment variable (see `config`).

pub const USAGE: &str = "\
Usage: hub-server [OPTIONS]

Options:
  --rest-port <PORT>              REST (Actix Web) port [env: REST_PORT] (alias: --restport)
  --grpc-port <PORT>              gRPC (tonic) port [env: GRPC_PORT]
  --database-url <URL>            Postgres as hubappusr (RLS enforced) [env: DATABASE_URL]
  --database-platform-url <URL>   Postgres as hubplatformusr (BYPASSRLS) [env: DATABASE_PLATFORM_URL]
  --redis-url <URL>               Redis [env: REDIS_URL]
  -h, --help                      Print this help

Flags override environment variables. A .env file in the working directory is
loaded if present (real environment variables win over it).";

/// Values given on the command line. `None` means "not passed; use the
/// environment".
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Args {
    pub rest_port: Option<u16>,
    pub grpc_port: Option<u16>,
    pub database_url: Option<String>,
    pub database_platform_url: Option<String>,
    pub redis_url: Option<String>,
}

/// Prints the error and usage to stderr and exits with status 2.
pub fn usage_error(msg: &str) -> ! {
    eprintln!("error: {msg}\n\n{USAGE}");
    std::process::exit(2);
}

/// Parses command-line flags. Accepts `--flag=value` and `--flag value`.
/// Returns `Ok(None)` when help was requested.
pub fn parse(args: impl IntoIterator<Item = String>) -> Result<Option<Args>, String> {
    let mut parsed = Args::default();
    let mut args = args.into_iter();

    while let Some(arg) = args.next() {
        // Split on the first `=` only; URLs may contain more.
        let (flag, inline_value) = match arg.split_once('=') {
            Some((flag, value)) => (flag.to_owned(), Some(value.to_owned())),
            None => (arg, None),
        };
        if matches!(flag.as_str(), "-h" | "--help") {
            return Ok(None);
        }

        let mut value = || match inline_value.clone() {
            Some(value) => Ok(value),
            None => args
                .next()
                .ok_or_else(|| format!("`{flag}` requires a value")),
        };

        match flag.as_str() {
            "--rest-port" | "--restport" => {
                parsed.rest_port = Some(parse_port(&flag, &value()?)?);
            }
            "--grpc-port" => parsed.grpc_port = Some(parse_port(&flag, &value()?)?),
            "--database-url" => parsed.database_url = Some(value()?),
            "--database-platform-url" => parsed.database_platform_url = Some(value()?),
            "--redis-url" => parsed.redis_url = Some(value()?),
            other => return Err(format!("unknown option `{other}`")),
        }
    }

    Ok(Some(parsed))
}

/// Parses a TCP port (1-65535). `source` names the flag or environment
/// variable the value came from, for the error message.
pub fn parse_port(source: &str, value: &str) -> Result<u16, String> {
    match value.trim().parse::<u16>() {
        Ok(0) | Err(_) => Err(format!(
            "invalid port `{value}` for {source} (expected 1-65535)"
        )),
        Ok(port) => Ok(port),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(args: &[&str]) -> Result<Option<Args>, String> {
        parse(args.iter().map(|a| (*a).to_owned()))
    }

    #[test]
    fn nothing_is_set_when_no_flags_are_passed() {
        assert_eq!(run(&[]), Ok(Some(Args::default())));
    }

    #[test]
    fn accepts_equals_and_space_forms() {
        let expected = Ok(Some(Args {
            rest_port: Some(9000),
            grpc_port: Some(9001),
            ..Args::default()
        }));
        assert_eq!(run(&["--rest-port=9000", "--grpc-port=9001"]), expected);
        assert_eq!(
            run(&["--rest-port", "9000", "--grpc-port", "9001"]),
            expected
        );
        assert_eq!(run(&["--restport=9000", "--grpc-port=9001"]), expected);
    }

    #[test]
    fn help_returns_none() {
        assert_eq!(run(&["--help"]), Ok(None));
    }

    #[test]
    fn rejects_bad_input() {
        assert!(run(&["--rest-port=0"]).is_err());
        assert!(run(&["--rest-port=70000"]).is_err());
        assert!(run(&["--grpc-port"]).is_err());
        assert!(run(&["--port=1"]).is_err());
    }

    #[test]
    fn url_flags_keep_everything_after_the_first_equals() {
        let args = run(&["--database-url=postgres://u:p@h/hub?sslmode=require"])
            .expect("parse")
            .expect("args");
        assert_eq!(
            args.database_url.as_deref(),
            Some("postgres://u:p@h/hub?sslmode=require")
        );
    }
}
