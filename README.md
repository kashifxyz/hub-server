# hub-server

The backend of **Hub**, the identity and access management (IAM) platform for our Cloud platform. Hub is the single source of truth for authentication and authorization, and for users, organizations, subscribed services, billing, usage, and policies.

One binary serves two APIs:

- **REST** (Actix Web): for browsers, the Hub console, and API clients
- **gRPC** (tonic): for other platform services

Storage is **PostgreSQL 18** (source of truth) and **Redis** (transient state only).

> Status: early foundation. The server starts, connects to PostgreSQL and Redis, and serves both ports (REST has no routes yet; gRPC exposes the standard health service).

---

## Prerequisites

- Rust stable, `1.98.1` or newer (`rust-toolchain.toml` pins the stable channel with `rustfmt` and `clippy`)
- PostgreSQL 18
- Redis

## Quick start

1. **Prepare the database** (one time, by hand): create the roles and the `hub` database by following [`docs/database/BOOTSTRAP.md`](docs/database/BOOTSTRAP.md).
2. **Configure**:

   ```sh
   cp .env.example .env
   # set the passwords in DATABASE_URL and DATABASE_PLATFORM_URL
   ```

3. **Run**:

   ```sh
   cargo run
   ```

   Expected output:

   ```text
   INF starting hub-server version=0.0.1
   INF connected to PostgreSQL database=hub server_version=18.4 server_time=... app_role=hubappusr platform_role=hubplatformusr
   INF connected to Redis redis_version=...
   INF REST server listening addr=127.0.0.1:8443
   INF gRPC server listening addr=127.0.0.1:50053
   ```

   Stop with `Ctrl+C`. Both servers drain in-flight requests before exiting.

## Configuration

Every setting comes from an environment variable. A `.env` file in the working directory is loaded if present, and real environment variables take precedence over it. A command-line flag overrides both. There are no built-in defaults: a missing setting stops startup with an error naming the variable and flag.

| Variable | Flag | Description |
| --- | --- | --- |
| `REST_PORT` | `--rest-port` (alias `--restport`) | REST port |
| `GRPC_PORT` | `--grpc-port` | gRPC port |
| `DATABASE_URL` | `--database-url` | PostgreSQL as `hubappusr` (runtime role, Row-Level Security enforced) |
| `DATABASE_PLATFORM_URL` | `--database-platform-url` | PostgreSQL as `hubplatformusr` (`BYPASSRLS`, platform admin and background jobs) |
| `REDIS_URL` | `--redis-url` | Redis |
| `LOG_LEVEL` | none | `trace`, `debug`, `info` (default), `warn`, `error`, `fatal` |

Flags accept `--flag=value` and `--flag value`:

```sh
cargo run -- --rest-port=9443 --grpc-port 50063
cargo run -- --help
```

Prefer `.env` for URLs: passwords passed as flags are visible in `ps` output and shell history.

Both servers listen on `127.0.0.1` only.

### Database roles

The server refuses to start unless the two database URLs use safe roles:

- `DATABASE_URL`'s role is not a superuser and has no `BYPASSRLS`, so Row-Level Security always applies to request handling.
- `DATABASE_PLATFORM_URL`'s role has `BYPASSRLS`.
- The two URLs use different roles.

The third role, `hubownerusr`, owns the database and runs migrations. The server never connects as it. See [`docs/database/BOOTSTRAP.md`](docs/database/BOOTSTRAP.md) for details.

## Project layout

A Cargo workspace. Members live in `crates/`:

| Crate | Responsibility |
| --- | --- |
| `hub-core` | Entry point (builds the `hub-server` binary): flags, settings, logging, startup and shutdown |
| `hub-http` | REST server (Actix Web) |
| `hub-grpc` | gRPC server (tonic) |
| `hub-db` | PostgreSQL pools (`hubappusr`, `hubplatformusr`) and the startup role check |
| `hub-cache` | Redis client |

Other paths:

- `docs/database/`: database documentation
- `proto/`: gRPC contracts
- `.env.example`: configuration template

To add a crate:

```sh
cargo new crates/hub-<name> --lib --vcs=none
```

Then add it to `members` and `[workspace.dependencies]` in the root `Cargo.toml`. Declare third-party dependency versions once in the root `[workspace.dependencies]`, and reference them from crates with `{ workspace = true }`.

## Development

```sh
cargo build                                        # build everything
cargo test                                         # all tests
cargo test -p hub-core                             # one crate
cargo test -p hub-core flags_override_env          # one test, by name
cargo clippy --workspace --all-targets -- -D warnings
cargo fmt --all
```

## Database migrations

Migrations live in `migrations/` as reversible `<timestamp>_<name>.up.sql` / `.down.sql` pairs (sqlx-cli). They run as the owner role `hubownerusr`, configured through `DATABASE_OWNER_URL` in `.env`; the server itself never uses it.

```sh
make migrate           # apply all pending migrations
make migrate-revert    # revert the most recently applied migration
make                   # list targets
```

Requires [sqlx-cli](https://crates.io/crates/sqlx-cli): `cargo install sqlx-cli --no-default-features --features postgres,rustls`.

## Logging

Logs use [loxide](https://crates.io/crates/loxide) in pretty format. Connection URLs and passwords are never logged: startup reports only role names, the database name, and server versions.
