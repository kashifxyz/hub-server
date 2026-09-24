-- =============================================================================
-- Users: identity, preferences, credentials, one-time tokens, MFA, sessions
-- =============================================================================
--
-- Tables:
--   users                human identity (one home organization each)
--   user_preferences     UI and notification settings
--   user_passwords       current password hash and lockout state
--   password_history     previous hashes, to prevent reuse
--   user_tokens          one-time tokens (email verification, password reset,
--                        account activation, email change)
--   user_totp_factors    TOTP authenticators (secret encrypted at rest)
--   user_recovery_codes  MFA recovery codes (hashed, single use)
--   user_passkeys        WebAuthn credentials
--   user_sessions        server-side sessions (token hashed)
--
-- Structure only (see the conventions in the audit_logs migration).
--
-- Row-Level Security:
--   * users: visible to the user themselves and inside their home org.
--   * all user_* tables: visible only to the user they belong to.
--
-- Lookup keys. Some flows run before the server knows which user or org to
-- set as context: login by email, redeeming a token from an email link,
-- validating a session cookie, and passkey sign-in. For these the server
-- sets exactly one lookup key for one transaction, which makes only the
-- matching row readable, then continues in the normal user context:
--   app.lookup_email          users.email (as stored: lowercase)
--   app.lookup_token_hash     user_tokens.token_hash (hex)
--   app.lookup_session_hash   user_sessions.token_hash (hex)
--   app.lookup_credential_id  user_passkeys.credential_id (hex)
-- Lookup keys grant read access only, never write access.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- users
-- -----------------------------------------------------------------------------

CREATE TABLE users (
    id                    uuid        PRIMARY KEY,

    -- The one organization this user belongs to. NULL only while a newly
    -- signed-up account is onboarding (it creates its organization next).
    home_organization_id  uuid        REFERENCES organizations (id) ON DELETE RESTRICT,

    -- Sign-in identifier, stored lowercase by the application. Unique among
    -- non-deleted users, so an address can be reused after account deletion.
    email                 text        NOT NULL,
    email_verified_at     timestamptz,

    -- Profile
    display_name          text,
    given_name            text,
    family_name           text,
    avatar_url            text,

    -- Lifecycle: 'pending_verification' | 'active' | 'suspended' | 'deactivated'
    status                text        NOT NULL,
    suspended_at          timestamptz,
    suspended_until       timestamptz,
    suspended_reason      text,
    deactivated_at        timestamptz,
    deactivated_reason    text,

    -- Legal consent
    terms_accepted_at     timestamptz,
    terms_version         text,
    privacy_accepted_at   timestamptz,

    -- Activity
    last_sign_in_at       timestamptz,
    last_sign_in_ip       inet,

    -- Deletion: requested by the user, soft-deleted, then purged by a job.
    deletion_requested_at timestamptz,
    deleted_at            timestamptz,
    purge_after           timestamptz,

    created_at            timestamptz NOT NULL,
    updated_at            timestamptz NOT NULL
);

COMMENT ON TABLE users IS
    'Human identities. Each belongs to exactly one home organization (NULL only during onboarding).';

CREATE UNIQUE INDEX users_email_key ON users (email) WHERE deleted_at IS NULL;
CREATE INDEX users_home_org_idx ON users (home_organization_id);
CREATE INDEX users_status_idx ON users (status) WHERE deleted_at IS NULL;
CREATE INDEX users_purge_after_idx ON users (purge_after) WHERE purge_after IS NOT NULL;

-- organizations.created_by could not reference users until now.
ALTER TABLE organizations
    ADD CONSTRAINT organizations_created_by_fkey
    FOREIGN KEY (created_by) REFERENCES users (id) ON DELETE SET NULL;

ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE users FORCE ROW LEVEL SECURITY;

CREATE POLICY users_select ON users
    FOR SELECT
    USING (
        id = NULLIF(current_setting('app.user_id', true), '')::uuid
        OR home_organization_id = NULLIF(current_setting('app.org_id', true), '')::uuid
    );

-- Login: the row with exactly the looked-up email.
CREATE POLICY users_lookup_email ON users
    FOR SELECT
    USING (email = NULLIF(current_setting('app.lookup_email', true), ''));

-- Sign-up: the app generates the user id and sets it as the user context.
-- Admin-created accounts: created inside the org context as the home org.
CREATE POLICY users_insert ON users
    FOR INSERT
    WITH CHECK (
        id = NULLIF(current_setting('app.user_id', true), '')::uuid
        OR home_organization_id = NULLIF(current_setting('app.org_id', true), '')::uuid
    );

CREATE POLICY users_update ON users
    FOR UPDATE
    USING (
        id = NULLIF(current_setting('app.user_id', true), '')::uuid
        OR home_organization_id = NULLIF(current_setting('app.org_id', true), '')::uuid
    )
    WITH CHECK (
        id = NULLIF(current_setting('app.user_id', true), '')::uuid
        OR home_organization_id = NULLIF(current_setting('app.org_id', true), '')::uuid
    );

-- No DELETE policy: users are soft-deleted; the platform role purges.


-- -----------------------------------------------------------------------------
-- user_preferences
-- -----------------------------------------------------------------------------

CREATE TABLE user_preferences (
    user_id                uuid        PRIMARY KEY REFERENCES users (id) ON DELETE CASCADE,

    locale                 text        NOT NULL,
    timezone               text        NOT NULL,
    -- 'system' | 'light' | 'dark' | 'amoled'
    theme                  text        NOT NULL,
    date_format            text        NOT NULL,
    -- '24h' | '12h'
    time_format            text        NOT NULL,

    email_notifications    boolean     NOT NULL,
    security_alert_emails  boolean     NOT NULL,
    marketing_emails       boolean     NOT NULL,

    updated_at             timestamptz NOT NULL
);

ALTER TABLE user_preferences ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_preferences FORCE ROW LEVEL SECURITY;

CREATE POLICY user_preferences_owner ON user_preferences
    FOR ALL
    USING (user_id = NULLIF(current_setting('app.user_id', true), '')::uuid)
    WITH CHECK (user_id = NULLIF(current_setting('app.user_id', true), '')::uuid);


-- -----------------------------------------------------------------------------
-- user_passwords and password_history
-- -----------------------------------------------------------------------------
-- Users who only sign in with SSO or passkeys have no row here.

CREATE TABLE user_passwords (
    user_id               uuid        PRIMARY KEY REFERENCES users (id) ON DELETE CASCADE,
    -- PHC string, for example '$argon2id$v=19$m=...,t=...,p=...$salt$hash'.
    password_hash         text        NOT NULL,
    -- Consecutive failed sign-ins; reset on success.
    failed_attempts       integer     NOT NULL,
    locked_until          timestamptz,
    -- Force a change at next sign-in (for example after an admin reset).
    must_change           boolean     NOT NULL,
    changed_at            timestamptz NOT NULL
);

ALTER TABLE user_passwords ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_passwords FORCE ROW LEVEL SECURITY;

CREATE POLICY user_passwords_owner ON user_passwords
    FOR ALL
    USING (user_id = NULLIF(current_setting('app.user_id', true), '')::uuid)
    WITH CHECK (user_id = NULLIF(current_setting('app.user_id', true), '')::uuid);


CREATE TABLE password_history (
    id             uuid        PRIMARY KEY,
    user_id        uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    password_hash  text        NOT NULL,
    created_at     timestamptz NOT NULL
);

CREATE INDEX password_history_user_idx ON password_history (user_id, created_at DESC);

ALTER TABLE password_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE password_history FORCE ROW LEVEL SECURITY;

CREATE POLICY password_history_owner ON password_history
    FOR ALL
    USING (user_id = NULLIF(current_setting('app.user_id', true), '')::uuid)
    WITH CHECK (user_id = NULLIF(current_setting('app.user_id', true), '')::uuid);


-- -----------------------------------------------------------------------------
-- user_tokens: one-time tokens sent by email
-- -----------------------------------------------------------------------------
-- Only a SHA-256 hash of the token is stored; the plaintext exists only in the
-- email link.

CREATE TABLE user_tokens (
    id            uuid        PRIMARY KEY,
    user_id       uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    -- 'email_verification' | 'password_reset' | 'account_activation' | 'email_change'
    purpose       text        NOT NULL,
    token_hash    bytea       NOT NULL UNIQUE,
    -- The address being verified, for 'email_change'.
    new_email     text,
    requested_ip  inet,
    expires_at    timestamptz NOT NULL,
    consumed_at   timestamptz,
    revoked_at    timestamptz,
    created_at    timestamptz NOT NULL
);

CREATE INDEX user_tokens_user_purpose_idx ON user_tokens (user_id, purpose)
    WHERE consumed_at IS NULL AND revoked_at IS NULL;
CREATE INDEX user_tokens_expires_idx ON user_tokens (expires_at);

ALTER TABLE user_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_tokens FORCE ROW LEVEL SECURITY;

CREATE POLICY user_tokens_owner ON user_tokens
    FOR ALL
    USING (user_id = NULLIF(current_setting('app.user_id', true), '')::uuid)
    WITH CHECK (user_id = NULLIF(current_setting('app.user_id', true), '')::uuid);

-- Redeeming an email link: the row with exactly the looked-up hash.
CREATE POLICY user_tokens_lookup ON user_tokens
    FOR SELECT
    USING (token_hash = decode(NULLIF(current_setting('app.lookup_token_hash', true), ''), 'hex'));


-- -----------------------------------------------------------------------------
-- MFA: TOTP factors, recovery codes, passkeys
-- -----------------------------------------------------------------------------

CREATE TABLE user_totp_factors (
    id                 uuid        PRIMARY KEY,
    user_id            uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    name               text        NOT NULL,
    -- The shared secret, encrypted by the application (AEAD). key_id names the
    -- encryption key version so keys can be rotated.
    secret_ciphertext  bytea       NOT NULL,
    secret_nonce       bytea       NOT NULL,
    key_id             text        NOT NULL,
    -- 'SHA1' | 'SHA256' | 'SHA512'
    algorithm          text        NOT NULL,
    digits             smallint    NOT NULL,
    period_seconds     smallint    NOT NULL,
    -- Last accepted time step, so a code can't be replayed within its window.
    last_used_step     bigint,
    -- NULL until the user confirms enrollment with a valid code.
    verified_at        timestamptz,
    last_used_at       timestamptz,
    disabled_at        timestamptz,
    created_at         timestamptz NOT NULL
);

CREATE INDEX user_totp_factors_user_idx ON user_totp_factors (user_id);

ALTER TABLE user_totp_factors ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_totp_factors FORCE ROW LEVEL SECURITY;

CREATE POLICY user_totp_factors_owner ON user_totp_factors
    FOR ALL
    USING (user_id = NULLIF(current_setting('app.user_id', true), '')::uuid)
    WITH CHECK (user_id = NULLIF(current_setting('app.user_id', true), '')::uuid);


CREATE TABLE user_recovery_codes (
    id          uuid        PRIMARY KEY,
    user_id     uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    code_hash   bytea       NOT NULL,
    used_at     timestamptz,
    created_at  timestamptz NOT NULL,

    UNIQUE (user_id, code_hash)
);

ALTER TABLE user_recovery_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_recovery_codes FORCE ROW LEVEL SECURITY;

CREATE POLICY user_recovery_codes_owner ON user_recovery_codes
    FOR ALL
    USING (user_id = NULLIF(current_setting('app.user_id', true), '')::uuid)
    WITH CHECK (user_id = NULLIF(current_setting('app.user_id', true), '')::uuid);


CREATE TABLE user_passkeys (
    id               uuid        PRIMARY KEY,
    user_id          uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    name             text        NOT NULL,
    credential_id    bytea       NOT NULL UNIQUE,
    public_key       bytea       NOT NULL,
    -- Authenticator model identifier.
    aaguid           uuid,
    sign_count       bigint      NOT NULL,
    -- 'usb' | 'nfc' | 'ble' | 'internal' | 'hybrid'
    transports       text[]      NOT NULL,
    backup_eligible  boolean     NOT NULL,
    backup_state     boolean     NOT NULL,
    last_used_at     timestamptz,
    created_at       timestamptz NOT NULL
);

CREATE INDEX user_passkeys_user_idx ON user_passkeys (user_id);

ALTER TABLE user_passkeys ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_passkeys FORCE ROW LEVEL SECURITY;

CREATE POLICY user_passkeys_owner ON user_passkeys
    FOR ALL
    USING (user_id = NULLIF(current_setting('app.user_id', true), '')::uuid)
    WITH CHECK (user_id = NULLIF(current_setting('app.user_id', true), '')::uuid);

-- Passkey sign-in: the credential presented by the authenticator.
CREATE POLICY user_passkeys_lookup ON user_passkeys
    FOR SELECT
    USING (credential_id = decode(NULLIF(current_setting('app.lookup_credential_id', true), ''), 'hex'));


-- -----------------------------------------------------------------------------
-- user_sessions: server-side sessions for the Hub console
-- -----------------------------------------------------------------------------
-- The cookie carries a random token; only its SHA-256 hash is stored. Rows are
-- kept after revocation or expiry for the "recent sessions" view and removed
-- by a cleanup job.

CREATE TABLE user_sessions (
    id                uuid        PRIMARY KEY,
    user_id           uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    token_hash        bytea       NOT NULL UNIQUE,

    -- How the session was established: 'password' | 'passkey' | 'saml'
    auth_method       text        NOT NULL,
    -- When MFA was last completed in this session (NULL if not yet).
    -- Also used for step-up checks before sensitive actions.
    mfa_verified_at   timestamptz,

    -- Client
    ip_address        inet,
    user_agent        text,
    device_name       text,
    country_code      text,

    -- Validity
    created_at        timestamptz NOT NULL,
    last_seen_at      timestamptz NOT NULL,
    idle_expires_at   timestamptz NOT NULL,
    expires_at        timestamptz NOT NULL,
    revoked_at        timestamptz,
    -- 'sign_out' | 'user_revoked' | 'admin_revoked' | 'password_changed' | ...
    revoked_reason    text
);

CREATE INDEX user_sessions_user_active_idx ON user_sessions (user_id, last_seen_at DESC)
    WHERE revoked_at IS NULL;
CREATE INDEX user_sessions_expires_idx ON user_sessions (expires_at);

ALTER TABLE user_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_sessions FORCE ROW LEVEL SECURITY;

CREATE POLICY user_sessions_owner ON user_sessions
    FOR ALL
    USING (user_id = NULLIF(current_setting('app.user_id', true), '')::uuid)
    WITH CHECK (user_id = NULLIF(current_setting('app.user_id', true), '')::uuid);

-- Validating a session cookie: the row with exactly the looked-up hash.
CREATE POLICY user_sessions_lookup ON user_sessions
    FOR SELECT
    USING (token_hash = decode(NULLIF(current_setting('app.lookup_session_hash', true), ''), 'hex'));
