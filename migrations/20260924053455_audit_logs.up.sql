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
--   * The one exception is seed data Hub needs to run (for example its own
--     permissions and system roles): seed INSERTs may call uuidv7() and
--     now() for their values. Nothing else in SQL generates values.
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
-- Partitions
-- -----------------------------------------------------------------------------
-- One per month, September 2026 through December 2027, plus a DEFAULT
-- partition as a safety net so an insert never fails for lack of a
-- partition. Later months are added by future migrations (or a scheduled
-- job) ahead of time, with the same REVOKE.
--
-- Partitions are only reachable through audit_logs: RLS policies and the
-- append-only grants are defined on the parent and do not apply when a
-- partition is queried directly, so the runtime roles get no access to the
-- partitions themselves.

CREATE TABLE audit_logs_2026_09 PARTITION OF audit_logs FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');
CREATE TABLE audit_logs_2026_10 PARTITION OF audit_logs FOR VALUES FROM ('2026-10-01') TO ('2026-11-01');
CREATE TABLE audit_logs_2026_11 PARTITION OF audit_logs FOR VALUES FROM ('2026-11-01') TO ('2026-12-01');
CREATE TABLE audit_logs_2026_12 PARTITION OF audit_logs FOR VALUES FROM ('2026-12-01') TO ('2027-01-01');
CREATE TABLE audit_logs_2027_01 PARTITION OF audit_logs FOR VALUES FROM ('2027-01-01') TO ('2027-02-01');
CREATE TABLE audit_logs_2027_02 PARTITION OF audit_logs FOR VALUES FROM ('2027-02-01') TO ('2027-03-01');
CREATE TABLE audit_logs_2027_03 PARTITION OF audit_logs FOR VALUES FROM ('2027-03-01') TO ('2027-04-01');
CREATE TABLE audit_logs_2027_04 PARTITION OF audit_logs FOR VALUES FROM ('2027-04-01') TO ('2027-05-01');
CREATE TABLE audit_logs_2027_05 PARTITION OF audit_logs FOR VALUES FROM ('2027-05-01') TO ('2027-06-01');
CREATE TABLE audit_logs_2027_06 PARTITION OF audit_logs FOR VALUES FROM ('2027-06-01') TO ('2027-07-01');
CREATE TABLE audit_logs_2027_07 PARTITION OF audit_logs FOR VALUES FROM ('2027-07-01') TO ('2027-08-01');
CREATE TABLE audit_logs_2027_08 PARTITION OF audit_logs FOR VALUES FROM ('2027-08-01') TO ('2027-09-01');
CREATE TABLE audit_logs_2027_09 PARTITION OF audit_logs FOR VALUES FROM ('2027-09-01') TO ('2027-10-01');
CREATE TABLE audit_logs_2027_10 PARTITION OF audit_logs FOR VALUES FROM ('2027-10-01') TO ('2027-11-01');
CREATE TABLE audit_logs_2027_11 PARTITION OF audit_logs FOR VALUES FROM ('2027-11-01') TO ('2027-12-01');
CREATE TABLE audit_logs_2027_12 PARTITION OF audit_logs FOR VALUES FROM ('2027-12-01') TO ('2028-01-01');
CREATE TABLE audit_logs_default PARTITION OF audit_logs DEFAULT;

REVOKE ALL ON TABLE
    audit_logs_2026_09, audit_logs_2026_10, audit_logs_2026_11, audit_logs_2026_12,
    audit_logs_2027_01, audit_logs_2027_02, audit_logs_2027_03, audit_logs_2027_04,
    audit_logs_2027_05, audit_logs_2027_06, audit_logs_2027_07, audit_logs_2027_08,
    audit_logs_2027_09, audit_logs_2027_10, audit_logs_2027_11, audit_logs_2027_12,
    audit_logs_default
FROM hubappusr, hubplatformusr;


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
