-- =============================================================================
-- Organizations: the tenant boundary and billing entity
-- =============================================================================
--
-- Every user belongs to exactly one home organization and may collaborate
-- with others. Ownership is not a column here: the Owner is whoever holds the
-- 'owner' role binding (see the authz migration), so ownership can be shared
-- and transferred like any other role.
--
-- Structure only (see the conventions in the audit_logs migration).
-- =============================================================================

CREATE TABLE organizations (
    id                  uuid        PRIMARY KEY,

    -- URL-safe identifier, stored lowercase by the application. Globally
    -- unique and never reused, even after deletion, so a deleted org's slug
    -- can't be impersonated.
    slug                text        NOT NULL UNIQUE,
    name                text        NOT NULL,
    description         text,
    logo_url            text,
    website_url         text,

    -- Contacts
    contact_email       text,
    billing_email       text,

    -- Defaults for members
    default_locale      text        NOT NULL,
    default_timezone    text        NOT NULL,

    -- Lifecycle: 'active' | 'suspended' | 'deactivated'
    status              text        NOT NULL,
    suspended_at        timestamptz,
    suspended_reason    text,
    deactivated_at      timestamptz,
    deactivated_reason  text,
    -- Soft delete. Purging (hard delete) is a background job after the
    -- retention window.
    deleted_at          timestamptz,
    purge_after         timestamptz,

    -- Organization-level settings that don't need their own columns yet.
    settings            jsonb       NOT NULL,

    -- The user who created the organization. The foreign key to users is
    -- added in the users migration (users is created after this table).
    created_by          uuid,

    created_at          timestamptz NOT NULL,
    updated_at          timestamptz NOT NULL
);

COMMENT ON TABLE organizations IS
    'Tenants. Ownership is expressed through role bindings, not a column.';

CREATE INDEX organizations_status_idx ON organizations (status) WHERE deleted_at IS NULL;
CREATE INDEX organizations_purge_after_idx ON organizations (purge_after) WHERE purge_after IS NOT NULL;


-- Row-Level Security: an organization is visible only inside its own context.
ALTER TABLE organizations ENABLE ROW LEVEL SECURITY;
ALTER TABLE organizations FORCE ROW LEVEL SECURITY;

CREATE POLICY organizations_select ON organizations
    FOR SELECT
    USING (id = NULLIF(current_setting('app.org_id', true), '')::uuid);

-- Creating an organization: the application generates the new id and sets it
-- as the org context before inserting.
CREATE POLICY organizations_insert ON organizations
    FOR INSERT
    WITH CHECK (id = NULLIF(current_setting('app.org_id', true), '')::uuid);

CREATE POLICY organizations_update ON organizations
    FOR UPDATE
    USING (id = NULLIF(current_setting('app.org_id', true), '')::uuid)
    WITH CHECK (id = NULLIF(current_setting('app.org_id', true), '')::uuid);

-- No DELETE policy: organizations are soft-deleted (deleted_at). Purging is
-- done by the platform role, which bypasses RLS.
