-- =============================================================================
-- Audit logs
-- =============================================================================
--
-- This is the first migration so every later change can be audited.
--
-- Conventions for all Hub migrations:
--   * The schema is structure only: tables, columns, NOT NULL, keys,
--     indexes, partitions, grants, and Row-Level Security policies.
--     No functions, triggers, CHECK constraints, or DEFAULT values.
--     Rust generates every value, including UUIDv7 primary keys and
--     timestamps, and performs all validation.
--   * Exceptions, and only these:
--       - Seed data Hub needs to run (for example its own permissions and
--         system roles): seed INSERTs may call uuidv7() and now().
--       - audit_logs partition management: one function,
--         audit_logs_ensure_partitions(), so monthly partitions are created
--         automatically (see below).
--   * Values Rust normalizes before storing (lowercase email and slugs) are
--     compared as stored.
--   * Run as hubownerusr (owner). Runtime roles: hubappusr (RLS enforced) and
--     hubplatformusr (BYPASSRLS). See docs/database/BOOTSTRAP.md.
--   * Every table with organization_id or user_id has ENABLE + FORCE row
--     level security and its policies in the same migration.
--
-- Row-Level Security context. The server sets these per transaction with
-- set_config('<name>', '<value or empty>', true) (transaction-local):
--   app.org_id   organization the request acts in (uuid)
--   app.user_id  user the request acts for (uuid)
-- Policies read them with NULLIF(current_setting('<name>', true), ''). An
-- unset setting reads as NULL (or '' once used on a connection), which
-- matches no row: policies fail closed.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Migration bookkeeping must not be writable by the runtime roles
-- -----------------------------------------------------------------------------
-- sqlx creates _sqlx_migrations as the owner before running this file, and the
-- default privileges from the bootstrap would otherwise grant DML on it.
REVOKE ALL ON TABLE _sqlx_migrations FROM hubappusr, hubplatformusr;


-- -----------------------------------------------------------------------------
-- audit_logs: append-only record of security, access, and billing changes
-- -----------------------------------------------------------------------------
-- No foreign keys on purpose: audit history must outlive the users,
-- organizations, and objects it describes. Partitioned by month on
-- occurred_at so old months can be archived or dropped cheaply.

CREATE TABLE audit_logs (
    id              uuid        NOT NULL,
    occurred_at     timestamptz NOT NULL,

    -- NULL for events outside any organization (sign-up, failed login,
    -- personal account changes).
    organization_id uuid,

    -- Who: 'user' | 'service_account' | 'system' | 'anonymous'
    actor_type      text        NOT NULL,
    actor_id        uuid,
    -- Human-readable actor at the time of the event (email, service account
    -- name), kept because the actor may later be renamed or deleted.
    actor_label     text,

    -- What: dotted verb, for example 'hub.user.signed_in',
    -- 'hub.member.role_granted', 'hub.organization.updated'.
    action          text        NOT NULL,

    -- On what (optional): for example 'user', 'organization', 'role'.
    target_type     text,
    target_id       uuid,
    target_label    text,

    -- Result: 'success' | 'failure' | 'denied'
    outcome         text        NOT NULL,
    -- Machine-readable reason for failure or denial.
    reason          text,

    -- Request context
    request_id      uuid,
    session_id      uuid,
    ip_address      inet,
    user_agent      text,

    -- Extra details, for example before/after values. Secrets must be
    -- redacted by the application before they reach this column.
    metadata        jsonb       NOT NULL,

    -- The partition key must be part of the primary key.
    PRIMARY KEY (id, occurred_at)
) PARTITION BY RANGE (occurred_at);

COMMENT ON TABLE audit_logs IS
    'Append-only audit trail. Written in the same transaction as the change it records.';

CREATE INDEX audit_logs_org_time_idx
    ON audit_logs (organization_id, occurred_at DESC);
CREATE INDEX audit_logs_actor_time_idx
    ON audit_logs (actor_type, actor_id, occurred_at DESC);
CREATE INDEX audit_logs_target_time_idx
    ON audit_logs (target_type, target_id, occurred_at DESC);
CREATE INDEX audit_logs_action_time_idx
    ON audit_logs (action, occurred_at DESC);

-- Append-only: the runtime roles may read and insert, never change or remove.
-- (Privileges on the parent govern access through the parent.)
REVOKE UPDATE, DELETE, TRUNCATE ON audit_logs FROM hubappusr, hubplatformusr;


-- -----------------------------------------------------------------------------
-- Partitions (created automatically)
-- -----------------------------------------------------------------------------
-- Monthly partitions are never listed by hand. audit_logs_ensure_partitions()
-- creates every missing partition from the current month up to
-- `months_ahead` months ahead. It is called:
--   * once at the end of this migration, and
--   * by hub-server at startup and then daily, through the platform role.
--
-- The DEFAULT partition is a safety net: if no partition exists yet for a
-- month (for example the server was down across a month boundary), rows land
-- there instead of failing, and the function moves them into the proper
-- monthly partition when it creates it.
--
-- Partitions are only reachable through audit_logs: RLS policies and the
-- append-only grants are defined on the parent and do not apply when a
-- partition is queried directly, so the runtime roles get no access to the
-- partitions themselves.

CREATE TABLE audit_logs_default PARTITION OF audit_logs DEFAULT;
REVOKE ALL ON TABLE audit_logs_default FROM hubappusr, hubplatformusr;

-- Runs as the owner (SECURITY DEFINER), because only the table owner may
-- create partitions. Executable only by hubplatformusr. Returns the number of
-- partitions created (0 when everything already exists).
--
-- TimeZone is pinned to UTC so month boundaries are midnight UTC no matter
-- which session calls it; otherwise a caller in another time zone would
-- create partitions that gap or overlap with existing ones.
CREATE FUNCTION audit_logs_ensure_partitions(months_ahead integer)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET TimeZone = 'UTC'
AS $$
DECLARE
    month_start date := date_trunc('month', now())::date;
    last_month  date := (date_trunc('month', now()) + make_interval(months => months_ahead))::date;
    month_end   date;
    part_name   text;
    created     integer := 0;
BEGIN
    -- One caller at a time (startup and the daily job may overlap).
    PERFORM pg_advisory_xact_lock(hashtext('audit_logs_ensure_partitions'));

    WHILE month_start <= last_month LOOP
        month_end := (month_start + INTERVAL '1 month')::date;
        part_name := format('audit_logs_%s', to_char(month_start, 'YYYY_MM'));

        IF to_regclass(format('public.%I', part_name)) IS NULL THEN
            -- Build the partition as a standalone table, move in any rows
            -- that landed in the DEFAULT partition for this month, then
            -- attach it. (Creating it directly would fail if DEFAULT already
            -- holds rows for the range.)
            EXECUTE format(
                'CREATE TABLE public.%I (LIKE public.audit_logs INCLUDING ALL)',
                part_name
            );
            EXECUTE format(
                'WITH moved AS (
                     DELETE FROM public.audit_logs_default
                     WHERE occurred_at >= %L AND occurred_at < %L
                     RETURNING *
                 )
                 INSERT INTO public.%I SELECT * FROM moved',
                month_start, month_end, part_name
            );
            EXECUTE format(
                'ALTER TABLE public.audit_logs ATTACH PARTITION public.%I FOR VALUES FROM (%L) TO (%L)',
                part_name, month_start, month_end
            );
            EXECUTE format(
                'REVOKE ALL ON TABLE public.%I FROM hubappusr, hubplatformusr',
                part_name
            );
            created := created + 1;
        END IF;

        month_start := month_end;
    END LOOP;

    RETURN created;
END
$$;

COMMENT ON FUNCTION audit_logs_ensure_partitions(integer) IS
    'Creates missing monthly audit_logs partitions up to months_ahead months ahead. Called by hub-server.';

REVOKE ALL ON FUNCTION audit_logs_ensure_partitions(integer) FROM PUBLIC, hubappusr;
GRANT EXECUTE ON FUNCTION audit_logs_ensure_partitions(integer) TO hubplatformusr;


-- -----------------------------------------------------------------------------
-- Row-Level Security
-- -----------------------------------------------------------------------------

ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_logs FORCE ROW LEVEL SECURITY;

-- Read: everything in the current organization, plus a user's own events
-- that happened outside any organization (login history, security events).
CREATE POLICY audit_logs_select ON audit_logs
    FOR SELECT
    USING (
        organization_id = NULLIF(current_setting('app.org_id', true), '')::uuid
        OR (organization_id IS NULL
            AND actor_type = 'user'
            AND actor_id = NULLIF(current_setting('app.user_id', true), '')::uuid)
    );

-- Write: events for the current organization, or events outside any
-- organization (which includes pre-login events such as failed sign-ins).
CREATE POLICY audit_logs_insert ON audit_logs
    FOR INSERT
    WITH CHECK (
        organization_id IS NULL
        OR organization_id = NULLIF(current_setting('app.org_id', true), '')::uuid
    );

-- No UPDATE or DELETE policies: with RLS enabled, those statements affect no
-- rows, on top of the revoked privileges above.


-- -----------------------------------------------------------------------------
-- Initial partitions: the current month and the next three
-- -----------------------------------------------------------------------------
SELECT audit_logs_ensure_partitions(3);
