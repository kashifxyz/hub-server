-- Reverts 20260924053459_users.up.sql.

DROP TABLE IF EXISTS user_sessions;
DROP TABLE IF EXISTS user_passkeys;
DROP TABLE IF EXISTS user_recovery_codes;
DROP TABLE IF EXISTS user_totp_factors;
DROP TABLE IF EXISTS user_tokens;
DROP TABLE IF EXISTS password_history;
DROP TABLE IF EXISTS user_passwords;
DROP TABLE IF EXISTS user_preferences;

ALTER TABLE organizations DROP CONSTRAINT IF EXISTS organizations_created_by_fkey;

DROP TABLE IF EXISTS users;
