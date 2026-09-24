-- =============================================================================
-- Authorization core: permissions, roles, role bindings
-- =============================================================================
--
-- Model: a role is a named set of permissions. A role binding grants one role
-- to one principal (user, group, or service account) inside one organization,
-- optionally narrowed to a single resource. An authorization check collects
-- the principal's bindings, expands them to permissions, and denies unless a
-- matching permission is found.
--
--   permissions       catalog of every permission, 'service.resource.action'
--   roles             system roles (organization_id NULL, shared by all orgs)
--                     and custom roles (owned by one organization)
--   role_permissions  which permissions each role grants
--   role_bindings     who holds which role, where
--
-- Structure only (see the conventions in the audit_logs migration), with one
-- exception: the seed data Hub needs to run at all (its own permissions and
-- the system roles). Seed rows are the only place uuidv7() and now() are
-- called in SQL; every other row gets its values from Rust.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- permissions (platform-wide catalog)
-- -----------------------------------------------------------------------------
-- Written only through the platform role (Hub's own permissions, and those
-- registered by platform services). The runtime app role may only read.

CREATE TABLE permissions (
    -- 'service.resource.action', for example 'hub.members.invite'
    permission    text        PRIMARY KEY,
    service       text        NOT NULL,
    resource      text        NOT NULL,
    action        text        NOT NULL,
    description   text        NOT NULL,
    -- Dangerous permissions get extra UI warnings and require recent
    -- authentication (step-up) before use.
    is_dangerous  boolean     NOT NULL,
    created_at    timestamptz NOT NULL,

    UNIQUE (service, resource, action)
);

COMMENT ON TABLE permissions IS
    'Catalog of all permissions. Read-only for hubappusr; written through hubplatformusr.';

REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON permissions FROM hubappusr;


-- -----------------------------------------------------------------------------
-- roles
-- -----------------------------------------------------------------------------

CREATE TABLE roles (
    id               uuid        PRIMARY KEY,
    -- NULL: system role, defined by Hub and available in every organization
    -- (read-only for organizations; written through the platform role).
    -- Otherwise a custom role of that organization.
    organization_id  uuid        REFERENCES organizations (id) ON DELETE CASCADE,
    -- Stable identifier, for example 'owner' or 'db-operators'.
    key              text        NOT NULL,
    name             text        NOT NULL,
    description      text,
    created_at       timestamptz NOT NULL,
    updated_at       timestamptz NOT NULL,

    -- System role keys are unique among system roles (NULLs compare equal);
    -- custom role keys are unique within their organization.
    UNIQUE NULLS NOT DISTINCT (organization_id, key)
);

COMMENT ON TABLE roles IS
    'System roles (organization_id NULL) and per-organization custom roles.';


-- -----------------------------------------------------------------------------
-- role_permissions
-- -----------------------------------------------------------------------------

CREATE TABLE role_permissions (
    role_id     uuid        NOT NULL REFERENCES roles (id) ON DELETE CASCADE,
    permission  text        NOT NULL REFERENCES permissions (permission) ON DELETE RESTRICT,
    created_at  timestamptz NOT NULL,

    PRIMARY KEY (role_id, permission)
);

CREATE INDEX role_permissions_permission_idx ON role_permissions (permission);


-- -----------------------------------------------------------------------------
-- role_bindings
-- -----------------------------------------------------------------------------
-- principal_id is polymorphic (users, groups, service accounts live in
-- different tables), so it has no foreign key; the application validates it
-- against principal_type.

CREATE TABLE role_bindings (
    id               uuid        PRIMARY KEY,
    organization_id  uuid        NOT NULL REFERENCES organizations (id) ON DELETE CASCADE,
    role_id          uuid        NOT NULL REFERENCES roles (id) ON DELETE RESTRICT,

    -- 'user' | 'group' | 'service_account'
    principal_type   text        NOT NULL,
    principal_id     uuid        NOT NULL,

    -- NULL: the binding applies to the whole organization. Otherwise it is
    -- narrowed to one resource, for example ('compute.instance', <id>).
    resource_type    text,
    resource_id      uuid,

    -- Optional end of a time-bound grant.
    expires_at       timestamptz,

    created_by       uuid        REFERENCES users (id) ON DELETE SET NULL,
    created_at       timestamptz NOT NULL,

    -- One binding per (org, role, principal, scope). Organization-wide
    -- bindings have a NULL scope; NULLs compare equal here.
    UNIQUE NULLS NOT DISTINCT
        (organization_id, role_id, principal_type, principal_id, resource_type, resource_id)
);

COMMENT ON TABLE role_bindings IS
    'Grants a role to a principal in an organization, optionally on one resource.';

CREATE INDEX role_bindings_principal_idx
    ON role_bindings (organization_id, principal_type, principal_id);
CREATE INDEX role_bindings_role_idx ON role_bindings (role_id);
CREATE INDEX role_bindings_resource_idx
    ON role_bindings (organization_id, resource_type, resource_id)
    WHERE resource_type IS NOT NULL;


-- -----------------------------------------------------------------------------
-- Seed data: Hub's permissions and the system roles
-- -----------------------------------------------------------------------------
-- Inserted before Row-Level Security is enabled below, because FORCE ROW
-- LEVEL SECURITY also applies to the owner running this migration.

INSERT INTO permissions (permission, service, resource, action, description, is_dangerous, created_at) VALUES
    ('hub.organization.read',            'hub', 'organization',  'read',            'View organization details.',                                 false, now()),
    ('hub.organization.update',          'hub', 'organization',  'update',          'Change organization name, contacts, and settings.',          false, now()),
    ('hub.organization.delete',          'hub', 'organization',  'delete',          'Delete the organization.',                                   true,  now()),
    ('hub.organization.manage_security', 'hub', 'organization',  'manage_security', 'Configure MFA requirements, SSO, and session policies.',     true,  now()),

    ('hub.members.list',                 'hub', 'members',       'list',            'List members and collaborators.',                            false, now()),
    ('hub.members.invite',               'hub', 'members',       'invite',          'Invite people to the organization.',                         false, now()),
    ('hub.members.update',               'hub', 'members',       'update',          'Change member profile details managed by the organization.', false, now()),
    ('hub.members.suspend',              'hub', 'members',       'suspend',         'Suspend or reactivate members.',                             true,  now()),
    ('hub.members.remove',               'hub', 'members',       'remove',          'Remove members and collaborators.',                          true,  now()),
    ('hub.members.revoke_sessions',      'hub', 'members',       'revoke_sessions', 'Sign members out of all sessions.',                          true,  now()),

    ('hub.roles.list',                   'hub', 'roles',         'list',            'View system and custom roles.',                              false, now()),
    ('hub.roles.create',                 'hub', 'roles',         'create',          'Create custom roles.',                                       false, now()),
    ('hub.roles.update',                 'hub', 'roles',         'update',          'Change the permissions of custom roles.',                    true,  now()),
    ('hub.roles.delete',                 'hub', 'roles',         'delete',          'Delete custom roles.',                                       true,  now()),

    ('hub.role_bindings.list',           'hub', 'role_bindings', 'list',            'See who holds which role.',                                  false, now()),
    ('hub.role_bindings.create',         'hub', 'role_bindings', 'create',          'Grant roles to users, groups, and service accounts.',        true,  now()),
    ('hub.role_bindings.delete',         'hub', 'role_bindings', 'delete',          'Revoke granted roles.',                                      true,  now()),

    ('hub.audit_logs.read',              'hub', 'audit_logs',    'read',            'Read the organization audit log.',                           false, now()),

    ('hub.billing.read',                 'hub', 'billing',       'read',            'View plan, usage, costs, and invoices.',                     false, now()),
    ('hub.billing.update',               'hub', 'billing',       'update',          'Change plan, payment details, and billing contacts.',        true,  now());

INSERT INTO roles (id, organization_id, key, name, description, created_at, updated_at) VALUES
    (uuidv7(), NULL, 'owner',          'Owner',          'Full control of the organization, including deletion and billing.',                          now(), now()),
    (uuidv7(), NULL, 'admin',          'Administrator',  'Manage members, roles, access, and settings. Cannot delete the organization or change billing.', now(), now()),
    (uuidv7(), NULL, 'security_admin', 'Security Admin', 'Manage security policies, suspend members, revoke sessions, and read the audit log.',        now(), now()),
    (uuidv7(), NULL, 'billing_admin',  'Billing Admin',  'Manage plan, payment details, and invoices.',                                                 now(), now()),
    (uuidv7(), NULL, 'member',         'Member',         'Standard member of the organization.',                                                        now(), now()),
    (uuidv7(), NULL, 'viewer',         'Viewer',         'Read-only access to the organization, members, and roles.',                                   now(), now());

INSERT INTO role_permissions (role_id, permission, created_at)
SELECT r.id, g.permission, now()
FROM (VALUES
    -- owner: every Hub permission
    ('owner', 'hub.organization.read'),
    ('owner', 'hub.organization.update'),
    ('owner', 'hub.organization.delete'),
    ('owner', 'hub.organization.manage_security'),
    ('owner', 'hub.members.list'),
    ('owner', 'hub.members.invite'),
    ('owner', 'hub.members.update'),
    ('owner', 'hub.members.suspend'),
    ('owner', 'hub.members.remove'),
    ('owner', 'hub.members.revoke_sessions'),
    ('owner', 'hub.roles.list'),
    ('owner', 'hub.roles.create'),
    ('owner', 'hub.roles.update'),
    ('owner', 'hub.roles.delete'),
    ('owner', 'hub.role_bindings.list'),
    ('owner', 'hub.role_bindings.create'),
    ('owner', 'hub.role_bindings.delete'),
    ('owner', 'hub.audit_logs.read'),
    ('owner', 'hub.billing.read'),
    ('owner', 'hub.billing.update'),

    -- admin: everything except deleting the organization and changing billing
    ('admin', 'hub.organization.read'),
    ('admin', 'hub.organization.update'),
    ('admin', 'hub.organization.manage_security'),
    ('admin', 'hub.members.list'),
    ('admin', 'hub.members.invite'),
    ('admin', 'hub.members.update'),
    ('admin', 'hub.members.suspend'),
    ('admin', 'hub.members.remove'),
    ('admin', 'hub.members.revoke_sessions'),
    ('admin', 'hub.roles.list'),
    ('admin', 'hub.roles.create'),
    ('admin', 'hub.roles.update'),
    ('admin', 'hub.roles.delete'),
    ('admin', 'hub.role_bindings.list'),
    ('admin', 'hub.role_bindings.create'),
    ('admin', 'hub.role_bindings.delete'),
    ('admin', 'hub.audit_logs.read'),
    ('admin', 'hub.billing.read'),

    -- security_admin
    ('security_admin', 'hub.organization.read'),
    ('security_admin', 'hub.organization.manage_security'),
    ('security_admin', 'hub.members.list'),
    ('security_admin', 'hub.members.suspend'),
    ('security_admin', 'hub.members.revoke_sessions'),
    ('security_admin', 'hub.roles.list'),
    ('security_admin', 'hub.role_bindings.list'),
    ('security_admin', 'hub.audit_logs.read'),

    -- billing_admin
    ('billing_admin', 'hub.organization.read'),
    ('billing_admin', 'hub.members.list'),
    ('billing_admin', 'hub.billing.read'),
    ('billing_admin', 'hub.billing.update'),

    -- member
    ('member', 'hub.organization.read'),
    ('member', 'hub.members.list'),

    -- viewer
    ('viewer', 'hub.organization.read'),
    ('viewer', 'hub.members.list'),
    ('viewer', 'hub.roles.list'),
    ('viewer', 'hub.role_bindings.list')
) AS g (role_key, permission)
JOIN roles r ON r.key = g.role_key AND r.organization_id IS NULL;


-- -----------------------------------------------------------------------------
-- Row-Level Security
-- -----------------------------------------------------------------------------

-- roles: system roles are visible everywhere and read-only; custom roles are
-- visible and writable only inside their organization.
ALTER TABLE roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE roles FORCE ROW LEVEL SECURITY;

CREATE POLICY roles_select ON roles
    FOR SELECT
    USING (
        organization_id IS NULL
        OR organization_id = NULLIF(current_setting('app.org_id', true), '')::uuid
    );

CREATE POLICY roles_insert ON roles
    FOR INSERT
    WITH CHECK (organization_id = NULLIF(current_setting('app.org_id', true), '')::uuid);

CREATE POLICY roles_update ON roles
    FOR UPDATE
    USING (organization_id = NULLIF(current_setting('app.org_id', true), '')::uuid)
    WITH CHECK (organization_id = NULLIF(current_setting('app.org_id', true), '')::uuid);

CREATE POLICY roles_delete ON roles
    FOR DELETE
    USING (organization_id = NULLIF(current_setting('app.org_id', true), '')::uuid);


-- role_permissions: follows the visibility and ownership of its role.
ALTER TABLE role_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE role_permissions FORCE ROW LEVEL SECURITY;

CREATE POLICY role_permissions_select ON role_permissions
    FOR SELECT
    USING (EXISTS (
        SELECT 1 FROM roles r
        WHERE r.id = role_permissions.role_id
          AND (r.organization_id IS NULL
               OR r.organization_id = NULLIF(current_setting('app.org_id', true), '')::uuid)
    ));

CREATE POLICY role_permissions_insert ON role_permissions
    FOR INSERT
    WITH CHECK (EXISTS (
        SELECT 1 FROM roles r
        WHERE r.id = role_permissions.role_id
          AND r.organization_id = NULLIF(current_setting('app.org_id', true), '')::uuid
    ));

CREATE POLICY role_permissions_delete ON role_permissions
    FOR DELETE
    USING (EXISTS (
        SELECT 1 FROM roles r
        WHERE r.id = role_permissions.role_id
          AND r.organization_id = NULLIF(current_setting('app.org_id', true), '')::uuid
    ));

-- No UPDATE policy: change a role's permissions by deleting and inserting rows.


-- role_bindings: only inside the organization.
ALTER TABLE role_bindings ENABLE ROW LEVEL SECURITY;
ALTER TABLE role_bindings FORCE ROW LEVEL SECURITY;

CREATE POLICY role_bindings_org ON role_bindings
    FOR ALL
    USING (organization_id = NULLIF(current_setting('app.org_id', true), '')::uuid)
    WITH CHECK (organization_id = NULLIF(current_setting('app.org_id', true), '')::uuid);
