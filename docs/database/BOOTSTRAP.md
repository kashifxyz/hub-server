# Database Bootstrap

How to prepare PostgreSQL for Hub by hand: roles, the database, and privileges. This is done **once per PostgreSQL cluster** (and again for each new environment). It is deliberately **not** automated in code or migrations: creating roles needs superuser rights, and the server must never have them.

Migrations (tables, RLS policies, functions) come after this and run as `hubownerusr`. They are not covered here.

---

## 1. What you will create

| Object | Purpose | Used by |
| --- | --- | --- |
| Role `hubownerusr` | Owns the `hub` database and every object in it | Migrations only. The server never connects as it |
| Role `hubappusr` | Runtime role. Row-Level Security (RLS) applies to it | The server, through `DATABASE_URL` |
| Role `hubplatformusr` | Bypasses RLS for platform administration and background jobs | The server, through `DATABASE_PLATFORM_URL` |
| Database `hub` | Hub's data | All three roles |

Why three roles:

- **RLS does not apply to superusers, to roles with `BYPASSRLS`, or to a table's owner** (unless the table uses `FORCE ROW LEVEL SECURITY`). If the server connected as the owner or a superuser, tenant isolation would silently stop working.
- So the owner (`hubownerusr`) is separate from the runtime role (`hubappusr`), and only one narrowly used role (`hubplatformusr`) can bypass RLS.

`hub-server` checks this at startup and **refuses to start** when:

- the `DATABASE_URL` role is a superuser or has `BYPASSRLS`
- the `DATABASE_PLATFORM_URL` role does not have `BYPASSRLS`
- both URLs connect as the same role

Required role attributes:

| Attribute | `hubownerusr` | `hubappusr` | `hubplatformusr` |
| --- | --- | --- | --- |
| `LOGIN` | yes | yes | yes |
| `SUPERUSER` | **no** | **no** | **no** |
| `BYPASSRLS` | no | **no** | **yes** |
| `CREATEDB` | optional, local only (§8) | no | no |
| `CREATEROLE` | no | no | no |
| Owns the database | **yes** | no | no |

---

## 2. Prerequisites

- **PostgreSQL 18.** Check with `psql --version` and `SELECT version();`.
- **Superuser access** to the cluster, for example the `postgres` role. You need it only for this guide.
- `psql` on your `PATH`.
- `password_encryption` set to `scram-sha-256`, which is the default since PostgreSQL 14:

  ```sql
  SHOW password_encryption;   -- expect: scram-sha-256
  ```

- `pg_hba.conf` allows password logins for these roles over TCP. For local development, lines like these (a `scram-sha-256` method, not `trust`):

  ```text
  # TYPE  DATABASE  USER  ADDRESS        METHOD
  host    hub       all   127.0.0.1/32   scram-sha-256
  host    hub       all   ::1/128        scram-sha-256
  ```

  Find the file with `SHOW hba_file;`. After editing it, reload with `SELECT pg_reload_conf();`.

  > With `trust`, any password (even a wrong one) is accepted. Don't use it for these roles, or a wrong `.env` password will go unnoticed.

---

## 3. Choose passwords

Use a different password for each role. Passwords go into URLs (`postgres://user:password@host/db`), so avoid the characters `@ : / ? # % +` or you'll have to percent-encode them. This generates URL-safe passwords:

```sh
openssl rand -base64 32 | tr -d '/+=' | cut -c1-32
```

Run it three times, once per role. Keep the values for `.env` (§7).

---

## 4. Create the roles

Connect to the cluster as a superuser:

```sh
psql -h localhost -U postgres -d postgres
```

Create the roles **without passwords** first:

```sql
CREATE ROLE hubownerusr    LOGIN NOSUPERUSER NOCREATEROLE NOBYPASSRLS;
CREATE ROLE hubappusr      LOGIN NOSUPERUSER NOCREATEROLE NOCREATEDB NOBYPASSRLS;
CREATE ROLE hubplatformusr LOGIN NOSUPERUSER NOCREATEROLE NOCREATEDB BYPASSRLS;
```

Then set each password interactively with `\password`. It prompts twice and sends only the hashed value, so the password never lands in `psql` history or server logs:

```text
\password hubownerusr
\password hubappusr
\password hubplatformusr
```

> Avoid `CREATE ROLE ... PASSWORD 'plain text'`. The statement can end up in `~/.psql_history` and, depending on `log_statement`, in the server log.

If the roles already exist (for example, you are re-running this guide), re-assert the safety-critical attributes instead of creating them:

```sql
ALTER ROLE hubownerusr    NOSUPERUSER NOBYPASSRLS;
ALTER ROLE hubappusr      NOSUPERUSER NOBYPASSRLS;
ALTER ROLE hubplatformusr NOSUPERUSER BYPASSRLS;
```

---

## 5. Create the database

Still connected as the superuser, to the `postgres` database:

```sql
CREATE DATABASE hub OWNER hubownerusr ENCODING 'UTF8' TEMPLATE template0;
```

Lock down who can connect. By default every role (`PUBLIC`) can connect to a new database, so revoke that and grant `CONNECT` only to the two runtime roles (the owner keeps its rights automatically):

```sql
REVOKE ALL ON DATABASE hub FROM PUBLIC;
GRANT CONNECT ON DATABASE hub TO hubappusr, hubplatformusr;
```

---

## 6. Schema and default privileges

Switch into the new database, still as the superuser:

```text
\c hub
```

### 6.1 Schema `public`

In PostgreSQL 15+ the `public` schema belongs to `pg_database_owner` (that is, `hubownerusr`) and `PUBLIC` can no longer create objects in it. Re-assert both explicitly so the setup doesn't depend on version defaults:

```sql
ALTER SCHEMA public OWNER TO hubownerusr;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO hubappusr, hubplatformusr;
```

### 6.2 Default privileges

Migrations create tables as `hubownerusr`. Default privileges make every future table, sequence, and function usable by the runtime roles without a `GRANT` in each migration. **Which rows** they can see is still decided by RLS policies, not by these grants.

```sql
-- Tables: read and write. No TRUNCATE, REFERENCES, or TRIGGER.
ALTER DEFAULT PRIVILEGES FOR ROLE hubownerusr IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO hubappusr, hubplatformusr;

-- Sequences (identity and serial columns)
ALTER DEFAULT PRIVILEGES FOR ROLE hubownerusr IN SCHEMA public
    GRANT USAGE, SELECT ON SEQUENCES TO hubappusr, hubplatformusr;

-- Functions: PostgreSQL lets PUBLIC execute every new function by default.
-- Remove that (globally: no IN SCHEMA, see the note below), then grant only
-- to the runtime roles.
ALTER DEFAULT PRIVILEGES FOR ROLE hubownerusr
    REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE hubownerusr IN SCHEMA public
    GRANT EXECUTE ON FUNCTIONS TO hubappusr, hubplatformusr;
```

> The `REVOKE` must **not** use `IN SCHEMA`. PostgreSQL only *adds* per-schema default privileges on top of the global ones, so a per-schema `REVOKE ... FROM PUBLIC` silently has no effect: every role would still be able to execute new functions.

> Default privileges apply only to objects created **by `hubownerusr`** after this point, and only in **this database**. Always run migrations as `hubownerusr`. If you recreate the database, run this section again.

Leave the session with `\q`.

---

## 7. Configure `hub-server`

Put the passwords from §3 into `hub-server/.env` (never commit it; `.env.example` is the template):

```sh
REST_PORT=8443
GRPC_PORT=50053
DATABASE_URL=postgres://hubappusr:<hubappusr password>@localhost:5432/hub
DATABASE_PLATFORM_URL=postgres://hubplatformusr:<hubplatformusr password>@localhost:5432/hub
REDIS_URL=redis://127.0.0.1:6379
LOG_LEVEL=info
```

`hubownerusr`'s URL is **not** part of the server configuration. Keep it wherever you run migrations from.

The same values can be passed as flags (`--database-url`, `--database-platform-url`, `--redis-url`), which override the environment. Prefer `.env`: flags expose passwords in `ps` output and shell history.

---

## 8. Optional: local development extras

**Let `hubownerusr` create databases.** This is needed later if tests create throwaway databases (for example `#[sqlx::test]`) or if you use `sqlx database create/drop`. Do this on local machines only, never in production:

```sql
ALTER ROLE hubownerusr CREATEDB;
```

**Connection limits.** These cap how many connections each role can hold. The server's pools use up to 10 connections each.

```sql
ALTER ROLE hubappusr      CONNECTION LIMIT 50;
ALTER ROLE hubplatformusr CONNECTION LIMIT 10;
```

---

## 9. Verify

Run these as the superuser (`psql -h localhost -U postgres -d hub`).

**Role attributes:**

```sql
SELECT rolname, rolsuper, rolbypassrls, rolcreatedb, rolcreaterole, rolcanlogin
FROM pg_roles
WHERE rolname IN ('hubownerusr', 'hubappusr', 'hubplatformusr')
ORDER BY rolname;
```

Expected (`rolcreatedb` is `t` for `hubownerusr` only if you applied §8):

```text
    rolname     | rolsuper | rolbypassrls | rolcreatedb | rolcreaterole | rolcanlogin
----------------+----------+--------------+-------------+---------------+-------------
 hubappusr      | f        | f            | f           | f             | t
 hubownerusr    | f        | f            | f           | f             | t
 hubplatformusr | f        | t            | f           | f             | t
```

**Database owner and access:**

```sql
SELECT datname, pg_get_userbyid(datdba) AS owner, datacl
FROM pg_database
WHERE datname = 'hub';
```

The owner must be `hubownerusr`. `datacl` should list `hubappusr=c` and `hubplatformusr=c` (`c` means CONNECT) and must **not** contain an entry starting with `=` (which would mean `PUBLIC`).

**Default privileges:** `\ddp` in `psql`, or:

```sql
SELECT pg_get_userbyid(defaclrole) AS owner,
       COALESCE(NULLIF(defaclnamespace, 0)::regnamespace::text, '(global)') AS schema,
       defaclobjtype AS type,
       defaclacl
FROM pg_default_acl
ORDER BY schema, type;
```

Expected (`r` tables, `S` sequences, `f` functions; `arwd` = SELECT/INSERT/UPDATE/DELETE, `rU` = SELECT/USAGE, `X` = EXECUTE):

```text
    owner    |  schema  | type |                          defaclacl
-------------+----------+------+--------------------------------------------------------------
 hubownerusr | (global) | f    | {hubownerusr=X/hubownerusr}
 hubownerusr | public   | S    | {hubappusr=rU/hubownerusr,hubplatformusr=rU/hubownerusr}
 hubownerusr | public   | f    | {hubappusr=X/hubownerusr,hubplatformusr=X/hubownerusr}
 hubownerusr | public   | r    | {hubappusr=arwd/hubownerusr,hubplatformusr=arwd/hubownerusr}
```

The `(global)` row has no `=X` entry, which confirms `PUBLIC` can't execute new functions.

**Each role can log in with its password** (from a normal shell, not as the superuser):

```sh
psql "postgres://hubappusr@localhost:5432/hub"      -c 'SELECT current_user;'
psql "postgres://hubplatformusr@localhost:5432/hub" -c 'SELECT current_user;'
psql "postgres://hubownerusr@localhost:5432/hub"    -c 'SELECT current_user;'
```

Each command prompts for that role's password.

**The server starts.** From `hub-server/`, with Redis running:

```sh
cargo run
```

Expected:

```text
INF starting hub-server version=...
INF connected to PostgreSQL app_role=hubappusr platform_role=hubplatformusr
INF connected to Redis
INF REST server listening addr=127.0.0.1:8443
INF gRPC server listening addr=127.0.0.1:50053
```

---

## 10. Troubleshooting

| Server error | Cause | Fix |
| --- | --- | --- |
| `role "hubappusr" does not exist` | §4 not done, or done in a different cluster or port | Create the roles. Check the host and port in the URL |
| `password authentication failed for user "..."` | Wrong password in `.env`, or `pg_hba.conf` method mismatch | Reset with `\password <role>` and update `.env`. Check §2 |
| `database "hub" does not exist` | §5 not done | Create the database |
| `permission denied for database hub` | `CONNECT` not granted | `GRANT CONNECT ON DATABASE hub TO hubappusr, hubplatformusr;` |
| `the app role ... must not be a superuser or have BYPASSRLS` | `DATABASE_URL` points to the wrong role, or `hubappusr` has too many rights | Point it to `hubappusr`. Run `ALTER ROLE hubappusr NOSUPERUSER NOBYPASSRLS;` |
| `the platform role ... must have BYPASSRLS` | `DATABASE_PLATFORM_URL` points to the wrong role, or `hubplatformusr` lacks the attribute | Point it to `hubplatformusr`. Run `ALTER ROLE hubplatformusr BYPASSRLS;` |
| `the app and platform pools must use different roles` | Both URLs use the same user | Use `hubappusr` and `hubplatformusr` respectively |
| `missing DATABASE_URL ...` (exit code 2) | Not set in the environment, `.env`, or flags | Add it to `hub-server/.env` (§7) |
| `connection refused` | PostgreSQL isn't running, or is on another port | Start it. Check with `pg_isready -h localhost -p 5432` |
| `permission denied for table ...` (later, after migrations) | Tables were created by a role other than `hubownerusr`, so the default privileges didn't apply | Run migrations as `hubownerusr`. Fix existing tables with `ALTER TABLE ... OWNER TO hubownerusr` and explicit `GRANT`s |

---

## 11. Rotating passwords

```text
psql -h localhost -U postgres -d postgres
\password hubappusr
```

Then update `DATABASE_URL` in `.env` and restart `hub-server`. Existing connections keep working until they close; new connections need the new password.

---

## 12. Starting over (local only)

This **permanently deletes all Hub data** in the cluster.

```sql
-- as the superuser, connected to the postgres database
DROP DATABASE IF EXISTS hub WITH (FORCE);

-- Default privileges and grants in other databases must be dropped
-- before the roles can be removed. Run once in each database the roles
-- touched, for example postgres:
DROP OWNED BY hubappusr, hubplatformusr, hubownerusr;

DROP ROLE IF EXISTS hubappusr;
DROP ROLE IF EXISTS hubplatformusr;
DROP ROLE IF EXISTS hubownerusr;
```

Then run this guide again from §4.
