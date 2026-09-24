-- Reverts 20260924053455_audit_logs.up.sql.
-- Dropping the parent drops every partition.

DROP TABLE IF EXISTS audit_logs;

-- The REVOKE on _sqlx_migrations is intentionally not undone: the runtime
-- roles must never be able to modify migration history.
