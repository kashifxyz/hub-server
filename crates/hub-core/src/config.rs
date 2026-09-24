//! Server settings: command-line flags applied over environment variables
//! (which include values loaded from `.env`). Nothing has a built-in default;
//! every setting must come from one or the other.

use crate::cli::{self, Args};

/// Settings after applying flags over environment variables.
pub struct Settings {
    pub rest_port: u16,
    pub grpc_port: u16,
    pub database_url: String,
    pub database_platform_url: String,
    pub redis_url: String,
}

/// Resolves every setting. A flag wins over its environment variable, and
/// every setting is required.
pub fn resolve(args: &Args, env: impl Fn(&str) -> Option<String>) -> Result<Settings, String> {
    let missing = |var: &str, flag: &str| {
        format!("missing {var} (set it in the environment or .env, or pass {flag})")
    };
    let env_value = |var: &str| env(var).filter(|v| !v.trim().is_empty());

    let port = |flag_value: Option<u16>, flag: &str, var: &str| match flag_value {
        Some(port) => Ok(port),
        None => {
            let raw = env_value(var).ok_or_else(|| missing(var, flag))?;
            cli::parse_port(var, &raw)
        }
    };
    let url = |flag_value: &Option<String>, flag: &str, var: &str| {
        flag_value
            .clone()
            .filter(|v| !v.trim().is_empty())
            .or_else(|| env_value(var))
            .ok_or_else(|| missing(var, flag))
    };

    let settings = Settings {
        rest_port: port(args.rest_port, "--rest-port", "REST_PORT")?,
        grpc_port: port(args.grpc_port, "--grpc-port", "GRPC_PORT")?,
        database_url: url(&args.database_url, "--database-url", "DATABASE_URL")?,
        database_platform_url: url(
            &args.database_platform_url,
            "--database-platform-url",
            "DATABASE_PLATFORM_URL",
        )?,
        redis_url: url(&args.redis_url, "--redis-url", "REDIS_URL")?,
    };

    if settings.rest_port == settings.grpc_port {
        return Err(format!(
            "REST and gRPC cannot share port {}",
            settings.rest_port
        ));
    }
    if settings.database_url == settings.database_platform_url {
        return Err(
            "DATABASE_URL and DATABASE_PLATFORM_URL must connect as different roles".into(),
        );
    }
    Ok(settings)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env(pairs: &'static [(&'static str, &'static str)]) -> impl Fn(&str) -> Option<String> {
        move |key| {
            pairs
                .iter()
                .find(|(k, _)| *k == key)
                .map(|(_, v)| (*v).to_owned())
        }
    }

    const ENV: &[(&str, &str)] = &[
        ("REST_PORT", "8443"),
        ("GRPC_PORT", "50053"),
        ("DATABASE_URL", "postgres://hubappusr@localhost/hub"),
        (
            "DATABASE_PLATFORM_URL",
            "postgres://hubplatformusr@localhost/hub",
        ),
        ("REDIS_URL", "redis://127.0.0.1:6379"),
    ];

    #[test]
    fn everything_comes_from_env_when_no_flags_are_passed() {
        let s = resolve(&Args::default(), env(ENV)).expect("resolve");
        assert_eq!(s.rest_port, 8443);
        assert_eq!(s.grpc_port, 50053);
        assert_eq!(s.database_url, "postgres://hubappusr@localhost/hub");
        assert_eq!(s.redis_url, "redis://127.0.0.1:6379");
    }

    #[test]
    fn flags_override_env() {
        let args = Args {
            rest_port: Some(9443),
            grpc_port: Some(50063),
            redis_url: Some("redis://10.0.0.5:6380".into()),
            ..Args::default()
        };
        let s = resolve(&args, env(ENV)).expect("resolve");
        assert_eq!(s.rest_port, 9443);
        assert_eq!(s.grpc_port, 50063);
        assert_eq!(s.redis_url, "redis://10.0.0.5:6380");
        assert_eq!(s.database_url, "postgres://hubappusr@localhost/hub");
    }

    #[test]
    fn missing_ports_are_errors() {
        const NO_PORTS: &[(&str, &str)] = &[
            ("DATABASE_URL", "postgres://hubappusr@localhost/hub"),
            (
                "DATABASE_PLATFORM_URL",
                "postgres://hubplatformusr@localhost/hub",
            ),
            ("REDIS_URL", "redis://127.0.0.1:6379"),
        ];
        let err = resolve(&Args::default(), env(NO_PORTS))
            .err()
            .expect("must fail");
        assert!(err.contains("REST_PORT"), "{err}");

        // A flag alone is enough for the port it covers.
        let args = Args {
            rest_port: Some(8443),
            ..Args::default()
        };
        let err = resolve(&args, env(NO_PORTS)).err().expect("must fail");
        assert!(err.contains("GRPC_PORT"), "{err}");
    }

    #[test]
    fn invalid_env_ports_are_errors() {
        const BAD: &[(&str, &str)] = &[
            ("REST_PORT", "eighty"),
            ("GRPC_PORT", "50053"),
            ("DATABASE_URL", "postgres://a@h/hub"),
            ("DATABASE_PLATFORM_URL", "postgres://b@h/hub"),
            ("REDIS_URL", "redis://h"),
        ];
        let err = resolve(&Args::default(), env(BAD))
            .err()
            .expect("must fail");
        assert!(err.contains("REST_PORT"), "{err}");
    }

    #[test]
    fn a_flag_can_create_a_port_clash() {
        let args = Args {
            grpc_port: Some(8443),
            ..Args::default()
        };
        assert!(resolve(&args, env(ENV)).is_err());
    }

    #[test]
    fn missing_or_identical_urls_are_errors() {
        const PORTS_ONLY: &[(&str, &str)] = &[("REST_PORT", "8443"), ("GRPC_PORT", "50053")];
        let err = resolve(&Args::default(), env(PORTS_ONLY))
            .err()
            .expect("must fail");
        assert!(err.contains("DATABASE_URL"), "{err}");

        let same = Args {
            database_url: Some("postgres://x@h/hub".into()),
            database_platform_url: Some("postgres://x@h/hub".into()),
            ..Args::default()
        };
        assert!(resolve(&same, env(ENV)).is_err());
    }
}
