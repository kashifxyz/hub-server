# Hub Data Model

The complete plan for what Hub stores, how it is structured, and the order it is built in. Migrations are written from this document; when the two disagree, fix one of them in the same change.

- **Status:** proposal for review. Sections marked **Decision needed** list the choices that must be confirmed before their migrations are written (collected in section 17).
- **Built so far:** batch 1 (`audit_logs`, `organizations`, `users` and credentials, `authz` core). Everything else here is planned.

---

## Contents

1. [Goals](#1-goals)
2. [Gap summary](#2-gap-summary)
3. [Conventions for every table](#3-conventions-for-every-table)
4. [Resource hierarchy](#4-resource-hierarchy)
5. [Identities](#5-identities)
6. [Organization membership and onboarding](#6-organization-membership-and-onboarding)
7. [Authentication and federation](#7-authentication-and-federation)
8. [Authorization](#8-authorization)
9. [Governance and guardrails](#9-governance-and-guardrails)
10. [Security posture](#10-security-posture)
11. [Audit](#11-audit)
12. [Services, subscriptions, and quotas](#12-services-subscriptions-and-quotas)
13. [Usage, cost, and billing](#13-usage-cost-and-billing)
14. [Platform plumbing](#14-platform-plumbing)
15. [Row-Level Security by table](#15-row-level-security-by-table)
16. [Build order](#16-build-order)
17. [Decisions needed](#17-decisions-needed)

---

## 1. Goals

Hub is the identity and access platform for a public cloud. The data model has to support what customers expect from AWS IAM, Google Cloud IAM, and Microsoft Entra ID / Azure RBAC:

| Capability | AWS | Google Cloud | Azure | Hub (this plan) |
| --- | --- | --- | --- | --- |
| Container hierarchy | Organization → OUs → Accounts | Organization → Folders → Projects | Tenant → Management groups → Subscriptions → Resource groups | Organization → Folders → Projects (section 4) |
| Human identities, groups | IAM users, Identity Center groups | Cloud Identity users, Google Groups | Entra users, groups | Users, groups (section 5) |
| Machine identities | IAM roles, access keys | Service accounts, keys, workload identity | Managed identities, service principals | Service accounts, keys, federated credentials (section 5.4) |
| Enterprise SSO and provisioning | SAML, SCIM | SAML, SCIM | SAML, SCIM | SAML connections, SCIM (section 7.3) |
| Role-based access | Policies attached to principals | Role bindings on resources | Role assignments at a scope | Role bindings at a scope (section 8) |
| Deny and conditions | Explicit deny, conditions | Deny policies, IAM Conditions | Deny assignments, conditions (ABAC) | Deny policies, conditions (sections 8.4 and 8.5) |
| Org-wide guardrails | Service control policies | Organization Policy constraints | Azure Policy | Organization policies (section 9.1) |
| Tags for access and cost | Tags | Tags and labels | Tags | Tags and labels (section 9.2) |
| Just-in-time elevation | IAM Identity Center temporary access | Privileged Access Manager | Privileged Identity Management | Eligible roles, access requests (section 9.3) |
| Access reviews | Access Analyzer findings | Policy Intelligence | Access reviews | Access reviews (section 9.4) |
| Tamper-evident audit | CloudTrail log file validation | Cloud Audit Logs | Activity log, immutable storage | Hourly signed audit digests (section 11.3) |
| Billing linked to projects | Consolidated billing per account | Billing accounts linked to projects | Billing per subscription | Billing accounts linked to projects (section 13) |
| Quotas | Service Quotas | Quotas per project | Quotas per subscription | Quotas and overrides per project (section 12.4) |
| Essential contacts | Alternate contacts | Essential Contacts | Notification contacts | Organization contacts (section 14.2) |

## 2. Gap summary

Every gap found in the batch 1 review, where this plan addresses it, and when it is built (section 16).

| # | Gap | Addressed in | Batch |
| --- | --- | --- | --- |
| 1 | No container hierarchy (folders, projects) for inheritance, billing, quotas | Section 4 | 2 |
| 2 | No groups | Section 5.3 | 2 |
| 3 | No service accounts or machine credentials | Section 5.4 | 2 |
| 4 | No collaborators, invitations, verified domains, home-org transfers | Section 6 | 2 |
| 5 | Role bindings scoped only to "org or loose resource", no concurrency control | Section 8.3 | 2 |
| 6 | No SAML connections, external identities, SCIM | Section 7.3 | 3 |
| 7 | No OAuth clients, refresh tokens, signing keys | Section 7.4 | 3 |
| 8 | No deny policies or conditions | Sections 8.4 and 8.5 | 4 |
| 9 | No organization-wide guardrails | Section 9.1 | 4 |
| 10 | No tags or labels | Section 9.2 | 4 |
| 11 | No just-in-time elevation | Section 9.3 | 4 |
| 12 | No access reviews | Section 9.4 | 4 |
| 13 | Audit log not tamper-evident; no log types, sinks, or retention settings | Section 11 | 2 (types), 5 (digests, sinks) |
| 14 | No organization security policies (MFA required, session limits, IP allowlists) | Section 10.1 | 2 |
| 15 | No recovery methods, trusted devices, or sign-in risk data | Sections 10.2–10.4 | 3 |
| 16 | Only the latest email and consent kept; no history | Section 5.2 | 2 |
| 17 | No service catalog, plans, subscriptions, entitlements, quotas | Section 12 | 5 |
| 18 | No usage, prices, invoices, credits, budgets | Section 13 | 5 |
| 19 | No event outbox for other services | Section 14.1 | 2 |
| 20 | No organization contacts | Section 14.2 | 2 |
| 21 | No idempotency keys | Section 14.3 | 5 |
| 22 | No region or data-residency fields | Section 14.4 | 2 |
| 23 | Inconsistent `created_by` / `updated_by` / version columns | Section 3.2 | 2 (applied to all tables) |
| 24 | No schema reference kept in sync with migrations | This document | Now |
| 25 | Email and slug uniqueness relies on Rust normalization | Section 3.5 | Now (rule + tests) |

## 3. Conventions for every table

### 3.1 The schema is structure only

Migrations contain tables, columns, `NOT NULL`, primary, foreign, and unique keys, indexes, partitions, grants, comments, and Row-Level Security policies. They contain **no functions, triggers, `CHECK` constraints, or `DEFAULT` values**. Rust generates every value (UUIDv7 IDs, timestamps, statuses) and performs all validation.

Two exceptions, and only these:

1. **Seed data** Hub needs to run (permissions, system roles, and later catalogs such as regions and organization policy constraints). Only seed `INSERT`s may call `uuidv7()` and `now()`. Seeds are inserted before `ENABLE ROW LEVEL SECURITY` in the same migration.
2. **Partition management**: `audit_logs_ensure_partitions()`, which creates monthly partitions automatically. hub-server calls it at startup and daily. If other tables are partitioned (usage records, section 13.1), how their partitions are managed is **Decision needed D4**.

### 3.2 Standard columns

| Column | Type | Rule |
| --- | --- | --- |
| `id` | `uuid` | Primary key, UUIDv7 generated in Rust |
| `organization_id` | `uuid` | On every tenant-owned table, for Row-Level Security, even when derivable through a parent |
| `created_at`, `updated_at` | `timestamptz` | Set by Rust, UTC |
| `created_by`, `updated_by` | `uuid` | Principal that made the change (user or service account; NULL for system). `ON DELETE SET NULL` where they reference users |
| `version` | `bigint` | On every table edited by administrators (policies, bindings, roles, settings). Starts at 1 and is incremented by Rust on each update. Writes use `WHERE id = $1 AND version = $2`; zero rows means someone else changed it first (the "etag" pattern used by Google Cloud IAM) |
| `deleted_at` | `timestamptz` | Soft delete for anything customers can restore; `purge_after` when a purge job follows |

Append-only tables (audit, usage, history) have `created_at` only: they are never updated.

### 3.3 Types

| Data | Type |
| --- | --- |
| Identifiers | `uuid` |
| Short text, enumerations | `text`, allowed values validated in Rust and documented in a column comment |
| Money | `bigint` in minor units (cents) plus `currency text` (ISO 4217) |
| Usage quantities | `numeric` |
| IP addresses and ranges | `inet`, `cidr` |
| Secrets | Only hashes (`bytea`, SHA-256) or ciphertext (`bytea` + nonce + key id); never plaintext |
| Flexible attributes | `jsonb`, only for data that is not queried or joined |

### 3.4 Names

- Tables: plural `snake_case` (`role_bindings`). Join tables: both names (`group_members`).
- Indexes: `<table>_<columns>_idx`; unique: `<table>_<columns>_key`; foreign keys: `<table>_<column>_fkey`.
- Status columns are named `status`; timestamps end in `_at`.

### 3.5 Normalization

Values compared case-insensitively (email addresses, slugs, domain names) are stored **lowercase**, and uniqueness is a plain unique constraint on the stored value (no expression indexes, per section 3.1). Rust normalizes in one shared function per kind, and a test covers every write path that stores them. Display casing, where it matters, is kept in a separate column (for example `organizations.name`).

### 3.6 Tenancy and Row-Level Security

Every table holding tenant or user data has `ENABLE` and `FORCE ROW LEVEL SECURITY`, with its policies in the same migration. Policies read the transaction-local context inline:

```sql
organization_id = NULLIF(current_setting('app.org_id', true), '')::uuid
```

Context values: `app.org_id`, `app.user_id`, and read-only lookup keys for flows that start before the user is known (`app.lookup_email`, `app.lookup_token_hash`, and so on). Section 15 lists the policy class of every table.

---

## 4. Resource hierarchy

**Decision needed D1.** Recommended: Google Cloud's model.

```text
Platform
└── Organization                        tenant, owns users, policies, billing accounts
    ├── Folder (optional, nestable)     groups projects by team, department, environment
    │   ├── Folder
    │   │   └── Project
    │   └── Project
    └── Project                         unit of billing, quotas, APIs, and isolation
        └── Resources                   owned by platform services (VMs, buckets, databases)
```

Why this shape:

- **Projects** are what a cloud bills, gives quotas to, and enables services in. Every resource belongs to exactly one project.
- **Folders** let large organizations delegate: a role granted on a folder applies to every project beneath it. Small customers never need them.
- **Inheritance** flows downward: access granted on the organization applies to all folders and projects; organization policies (section 9.1) and tags (section 9.2) inherit the same way.

### 4.1 `folders`

| Column | Type | Notes |
| --- | --- | --- |
| `id` | `uuid` | |
| `organization_id` | `uuid` NOT NULL | FK `organizations` |
| `parent_folder_id` | `uuid` | FK `folders`; NULL means directly under the organization |
| `display_name` | `text` NOT NULL | Unique among siblings (enforced in Rust) |
| `status` | `text` NOT NULL | `active`, `delete_requested` |
| standard columns | | `created_*`, `updated_*`, `version`, `deleted_at`, `purge_after` |

Rust prevents cycles and limits depth to 10 levels.

### 4.2 `projects`

| Column | Type | Notes |
| --- | --- | --- |
| `id` | `uuid` | Internal identifier |
| `organization_id` | `uuid` NOT NULL | FK `organizations` |
| `folder_id` | `uuid` | FK `folders`; NULL means directly under the organization |
| `slug` | `text` NOT NULL UNIQUE | Globally unique, lowercase, never reused (like a Google Cloud project ID) |
| `display_name` | `text` NOT NULL | |
| `billing_account_id` | `uuid` | FK `billing_accounts` (section 13.2); NULL until billing is linked |
| `region_policy` | `text[]` | Allowed regions for this project's data (section 14.4) |
| `labels` | `jsonb` NOT NULL | Free-form key/value labels (section 9.2) |
| `status` | `text` NOT NULL | `active`, `suspended`, `delete_requested` |
| `delete_requested_at` | `timestamptz` | Starts a 30-day restore window, then purge |
| standard columns | | including `version`, `deleted_at`, `purge_after` |

### 4.3 `hierarchy_paths` (closure table)

Answers "what are all the ancestors of this project?" in one indexed query, which every authorization check needs.

| Column | Type | Notes |
| --- | --- | --- |
| `organization_id` | `uuid` NOT NULL | |
| `ancestor_type`, `ancestor_id` | `text`, `uuid` | `organization`, `folder`, or `project` |
| `descendant_type`, `descendant_id` | `text`, `uuid` | `folder` or `project` |
| `depth` | `integer` NOT NULL | 0 for the node itself |

Primary key `(ancestor_id, descendant_id)`; index on `(descendant_id, depth)`. Maintained by Rust in the same transaction that creates or moves a folder or project (there are no triggers).

### 4.4 Resources

Hub does **not** store every VM or bucket: those live in the services that own them. A service identifies a resource to Hub as `(project_id, resource_type, resource_id)` in each authorization check, and Hub resolves inheritance from the project upward.

Hub stores a resource only when something is attached to it directly (a role binding, tag, or deny rule):

**`resources`**: `id`, `organization_id`, `project_id` (FK), `resource_type` (`service.kind`, for example `compute.instance`), `external_id` (the owning service's ID), `display_name`, `created_*`. Unique `(project_id, resource_type, external_id)`.

### 4.5 Scopes

Everything that "applies somewhere" (role bindings, deny policies, organization policies, tag bindings, quotas) uses the same two columns:

- `scope_type`: `organization`, `folder`, `project`, `resource`, or `billing_account`
- `scope_id`: the ID of that object

plus `organization_id` for Row-Level Security.

---

## 5. Identities

### 5.1 Principals

A principal is anything that can hold access:

| Principal type | Table | Example |
| --- | --- | --- |
| `user` | `users` | A person |
| `group` | `groups` | `platform-team@example.com` |
| `service_account` | `service_accounts` | `ci-deployer@my-project` |
| `domain` | `organization_domains` | Everyone with a verified `@example.com` address |
| `all_members` | none | Every member of the organization |

Principals are referenced as `(principal_type, principal_id)`. The ID has no foreign key because it can point at different tables; Rust validates it.

### 5.2 Users (additions to batch 1)

`users` stays as built. Additions:

**`user_email_history`** (append-only): `id`, `user_id`, `old_email`, `new_email`, `changed_by`, `changed_at`. Keeps a record when an address changes, for audit, support, and account recovery.

**`user_consents`** (append-only): `id`, `user_id`, `document` (`terms`, `privacy`, `dpa`), `version`, `accepted_at`, `ip_address`, `user_agent`. Replaces relying on the single `terms_version` column. The `users` columns remain as a cached "latest".

### 5.3 Groups

**`groups`**

| Column | Type | Notes |
| --- | --- | --- |
| `id` | `uuid` | |
| `organization_id` | `uuid` NOT NULL | |
| `email` | `text` | Optional group address, unique per organization |
| `display_name` | `text` NOT NULL | |
| `description` | `text` | |
| `source` | `text` NOT NULL | `hub` (managed here) or `scim` (managed by the organization's identity provider; read-only in Hub) |
| `external_id` | `text` | The identity provider's ID when `source = scim` |
| standard columns | | including `version`, `deleted_at` |

**`group_members`**

| Column | Type | Notes |
| --- | --- | --- |
| `organization_id` | `uuid` NOT NULL | |
| `group_id` | `uuid` NOT NULL | FK `groups` |
| `member_type`, `member_id` | `text`, `uuid` | `user`, `service_account`, or `group` (nested groups) |
| `role` | `text` NOT NULL | `member`, `manager`, `owner` (who may manage the group) |
| `expires_at` | `timestamptz` | Time-limited membership |
| `created_*` | | |

Primary key `(group_id, member_type, member_id)`. Rust prevents cycles and limits nesting depth to 5. Effective membership (direct plus nested) is computed in Rust and cached in Redis.

### 5.4 Service accounts

**`service_accounts`**

| Column | Type | Notes |
| --- | --- | --- |
| `id` | `uuid` | |
| `organization_id` | `uuid` NOT NULL | |
| `project_id` | `uuid` NOT NULL | Owning project |
| `slug` | `text` NOT NULL | Unique per project; addressed as `<slug>@<project-slug>` |
| `display_name`, `description` | `text` | |
| `status` | `text` NOT NULL | `active`, `disabled` |
| `last_used_at` | `timestamptz` | For unused-account reports |
| standard columns | | including `version`, `deleted_at` |

**`service_account_keys`**: how a service account authenticates.

| Column | Type | Notes |
| --- | --- | --- |
| `id` | `uuid` | Also the key ID shown to customers |
| `organization_id`, `service_account_id` | `uuid` NOT NULL | |
| `key_type` | `text` NOT NULL | `public_key` (customer holds the private key; preferred) or `secret` (Hub-generated secret shown once) |
| `public_key` | `bytea` | For `public_key` keys |
| `secret_hash` | `bytea` | SHA-256 of the secret, for `secret` keys |
| `secret_prefix` | `text` | First characters, shown in lists (`hsk_ab12…`) |
| `expires_at`, `last_used_at`, `disabled_at` | `timestamptz` | |
| `created_*` | | |

**`federated_credentials`**: keyless workload identity (for example a CI pipeline proving its identity with its own OIDC token), like Google Cloud workload identity federation and Azure federated credentials.

| Column | Type | Notes |
| --- | --- | --- |
| `id`, `organization_id`, `service_account_id` | `uuid` | |
| `issuer` | `text` NOT NULL | External token issuer URL |
| `subject` | `text` NOT NULL | Required `sub` claim |
| `audiences` | `text[]` NOT NULL | Accepted `aud` values |
| `attribute_conditions` | `text` | Extra claim conditions (same expression language as section 8.5) |
| standard columns | | |

### 5.5 API keys

API keys identify a calling project for low-risk APIs (like Google Cloud API keys). They are not principals and grant no IAM permissions on their own.

**`api_keys`**: `id`, `organization_id`, `project_id`, `display_name`, `key_hash` (`bytea`, unique), `key_prefix`, `restrictions` (`jsonb`: allowed APIs, referrers, IP ranges), `expires_at`, `last_used_at`, `disabled_at`, standard columns.

---

## 6. Organization membership and onboarding

### 6.1 Collaborators

A collaborator is a user from another organization who has been given access here. Their account stays governed by their home organization.

**`organization_collaborators`**: `organization_id`, `user_id` (FK `users`), `status` (`active`, `suspended`), `invited_by`, `joined_at`, `removed_at`, standard columns. Primary key `(organization_id, user_id)`.

The `users` read policy gains a third clause: a user is visible in an organization where they are an active collaborator (limited columns, through a view).

### 6.2 Invitations

**`organization_invitations`**

| Column | Type | Notes |
| --- | --- | --- |
| `id`, `organization_id` | `uuid` | |
| `email` | `text` NOT NULL | Lowercase |
| `kind` | `text` NOT NULL | `member` (creates an account in this organization) or `collaborator` (existing account elsewhere) |
| `initial_bindings` | `jsonb` NOT NULL | Roles to grant on acceptance (scope + role) |
| `token_hash` | `bytea` NOT NULL UNIQUE | |
| `status` | `text` NOT NULL | `pending`, `accepted`, `declined`, `revoked`, `expired` |
| `expires_at`, `accepted_at` | `timestamptz` | |
| `accepted_by` | `uuid` | |
| `created_*` | | |

### 6.3 Verified domains

**`organization_domains`**: `id`, `organization_id`, `domain` (lowercase, **unique globally**: a domain belongs to one organization), `verification_token` (published in DNS; not a secret), `status` (`pending`, `verified`, `failed`), `verified_at`, `last_checked_at`, `auto_join` (boolean), `sso_connection_id` (FK section 7.3; users on this domain sign in through it), standard columns.

**`public_email_domains`** (platform catalog, seeded): `domain` (primary key), `created_at`. Domains organizations may not claim (gmail.com, outlook.com, …).

### 6.4 Home organization transfers

**`home_org_transfer_requests`**: `id`, `user_id`, `from_organization_id`, `to_organization_id`, `requested_by`, `status` (`pending`, `accepted`, `declined`, `expired`, `cancelled`), `expires_at`, `decided_at`, `created_at`. Visible to both organizations and the user (section 15).

---

## 7. Authentication and federation

### 7.1 Built in batch 1

`user_passwords`, `password_history`, `user_tokens`, `user_totp_factors`, `user_recovery_codes`, `user_passkeys`, `user_sessions`. No changes, except that `user_sessions` gains `organization_id` (the organization the session last acted in, for "sign out everyone in this organization") and `trusted_device_id` (section 10.3).

### 7.2 Password policy

Minimum length, reuse history depth, and maximum age come from the organization security policy (section 10.1), with platform defaults in Rust. No extra table.

### 7.3 Enterprise SSO (SAML) and provisioning (SCIM)

**`saml_connections`**

| Column | Type | Notes |
| --- | --- | --- |
| `id`, `organization_id` | `uuid` | |
| `display_name` | `text` NOT NULL | |
| `idp_entity_id` | `text` NOT NULL | |
| `idp_sso_url` | `text` NOT NULL | |
| `idp_metadata_url` | `text` | Optional, for automatic certificate refresh |
| `name_id_format` | `text` NOT NULL | |
| `attribute_mapping` | `jsonb` NOT NULL | IdP attributes → email, names, groups |
| `group_mapping` | `jsonb` NOT NULL | IdP group names → Hub groups |
| `jit_provisioning` | `boolean` NOT NULL | Create users on first sign-in |
| `idp_initiated_allowed` | `boolean` NOT NULL | Off by default |
| `status` | `text` NOT NULL | `draft`, `testing`, `active`, `disabled` |
| standard columns | | including `version` |

**`saml_certificates`**: `id`, `organization_id`, `connection_id`, `certificate` (PEM), `fingerprint_sha256`, `not_before`, `not_after`, `status` (`active`, `next`, `retired`), `created_at`. Several at once allow rollover without downtime.

**`external_identities`**: links a user to an identity at an external provider.

| Column | Type | Notes |
| --- | --- | --- |
| `id`, `organization_id`, `user_id` | `uuid` | |
| `provider_type` | `text` NOT NULL | `saml`, `scim` |
| `connection_id` | `uuid` NOT NULL | |
| `external_subject` | `text` NOT NULL | SAML NameID or SCIM `externalId` |
| `last_login_at` | `timestamptz` | |
| `created_at` | | |

Unique `(connection_id, external_subject)`.

**`saml_assertion_replays`** is **not** a table: seen assertion IDs live in Redis with a TTL matching the assertion's validity window.

**`scim_tokens`**: `id`, `organization_id`, `connection_id`, `token_hash` (unique), `token_prefix`, `expires_at`, `last_used_at`, `revoked_at`, `created_*`. Users and groups created through SCIM are marked with `source = 'scim'` and an `external_id`.

### 7.4 Hub as the sign-in provider for platform apps (OAuth 2.1 / OpenID Connect)

**`oauth_clients`**: first-party platform applications.

| Column | Type | Notes |
| --- | --- | --- |
| `id` | `uuid` | Also the public `client_id` |
| `display_name` | `text` NOT NULL | |
| `client_type` | `text` NOT NULL | `public` (browser, CLI; PKCE, no secret) or `confidential` |
| `redirect_uris` | `text[]` NOT NULL | Exact-match only |
| `allowed_grant_types` | `text[]` NOT NULL | `authorization_code`, `refresh_token`, `client_credentials`, `device_code` |
| `allowed_scopes` | `text[]` NOT NULL | |
| `access_token_ttl_seconds`, `refresh_token_ttl_seconds` | `integer` NOT NULL | |
| `status` | `text` NOT NULL | `active`, `disabled` |
| standard columns | | |

Platform-global (no `organization_id`): only Hub operators register first-party apps.

**`oauth_client_secrets`**: `id`, `client_id`, `secret_hash`, `secret_prefix`, `expires_at`, `revoked_at`, `created_at`. Several at once for rotation.

**`oauth_refresh_tokens`**

| Column | Type | Notes |
| --- | --- | --- |
| `id` | `uuid` | |
| `client_id`, `user_id` | `uuid` NOT NULL | |
| `session_id` | `uuid` | The Hub session it came from; signing out revokes it |
| `family_id` | `uuid` NOT NULL | All tokens from one sign-in; reuse of a rotated token revokes the whole family |
| `token_hash` | `bytea` NOT NULL UNIQUE | |
| `scopes` | `text[]` NOT NULL | |
| `expires_at`, `rotated_at`, `revoked_at` | `timestamptz` | |
| `created_at` | | |

Authorization codes and device codes are short-lived (minutes) and live only in Redis.

**`signing_keys`**: keys Hub signs tokens with.

| Column | Type | Notes |
| --- | --- | --- |
| `id` | `uuid` | |
| `kid` | `text` NOT NULL UNIQUE | Published in the JWKS |
| `algorithm` | `text` NOT NULL | `EdDSA` or `ES256` |
| `public_key` | `bytea` NOT NULL | |
| `private_key_ciphertext`, `private_key_nonce` | `bytea` NOT NULL | Encrypted by the application |
| `encryption_key_id` | `text` NOT NULL | Which key-encryption key wrapped it |
| `status` | `text` NOT NULL | `next` (published, not used yet), `active` (signing), `retired` (published until issued tokens expire), `revoked` |
| `activated_at`, `retired_at`, `revoked_at` | `timestamptz` | |
| `created_at` | | |

Platform-global; readable and writable only through the platform role.

---

## 8. Authorization

### 8.1 How a decision is made

For `check(principal, permission, resource)`:

1. Resolve the principal: the user or service account, plus every group it belongs to (nested), plus `domain` and `all_members` where they apply.
2. Resolve the resource's ancestors: resource → project → folders → organization (`hierarchy_paths`).
3. **Organization policies** (section 9.1) that forbid the action deny it.
4. **Deny policies** (section 8.4) on any ancestor that match the principal and permission, and whose condition holds, deny it.
5. **Role bindings** (section 8.3) on any ancestor, for any of the principal's identities, whose role grants the permission, that are not expired, and whose condition holds, allow it.
6. Otherwise deny.

The result records which step decided, for the "why do I (not) have access?" explanation.

### 8.2 Permissions and roles (batch 1, with additions)

`permissions` gains `stage` (`ga`, `beta`, `deprecated`) and `scope_types text[]` (where the permission can be granted, for example `compute.instance.start` on `project` and `resource`).

`roles` gains:

| Column | Notes |
| --- | --- |
| `stage` | `ga`, `beta`, `deprecated`; deprecated system roles keep working but can't be newly granted |
| `assignable_scopes` | `text[]`: scope types where the role may be bound |
| `version` | Optimistic concurrency for custom-role edits |
| `created_by`, `updated_by` | Standard columns |

System roles gain per-service predefined roles as services onboard (for example `compute.admin`, `compute.viewer`), registered through the catalog API.

### 8.3 Role bindings (reworked)

Batch 1's `role_bindings` is replaced by the scope model:

| Column | Type | Notes |
| --- | --- | --- |
| `id` | `uuid` | |
| `organization_id` | `uuid` NOT NULL | |
| `scope_type`, `scope_id` | `text`, `uuid` NOT NULL | Section 4.5 |
| `role_id` | `uuid` NOT NULL | FK `roles` |
| `principal_type`, `principal_id` | `text`, `uuid` | Section 5.1 (`principal_id` NULL for `all_members`) |
| `condition_expression` | `text` | Optional (section 8.5) |
| `condition_title` | `text` | Human-readable label for the condition |
| `expires_at` | `timestamptz` | Time-bound grant |
| `source` | `text` NOT NULL | `direct`, `invitation`, `access_request` (section 9.3), `scim` |
| `source_id` | `uuid` | The invitation or access request that created it |
| standard columns | | including `version` |

Unique (nulls equal) on `(scope_type, scope_id, role_id, principal_type, principal_id, condition_expression)`.

### 8.4 Deny policies

**`deny_policies`**: `id`, `organization_id`, `scope_type`, `scope_id`, `display_name`, `description`, `status` (`active`, `disabled`), standard columns including `version`.

**`deny_rules`**

| Column | Type | Notes |
| --- | --- | --- |
| `id`, `organization_id`, `deny_policy_id` | `uuid` | |
| `denied_principals` | `jsonb` NOT NULL | List of principals (section 5.1) |
| `exception_principals` | `jsonb` NOT NULL | Principals exempt from this rule (for example break-glass admins) |
| `denied_permissions` | `text[]` NOT NULL | Wildcards allowed per service (`compute.*`) |
| `exception_permissions` | `text[]` NOT NULL | |
| `condition_expression` | `text` | Section 8.5 |
| `created_*` | | |

### 8.5 Conditions

Conditions are stored as expression text and evaluated in Rust. **Decision needed D2**: the expression language. Recommended: CEL (Common Expression Language), the language Google Cloud IAM Conditions and Kubernetes use, with a fixed set of attributes:

| Attribute | Example |
| --- | --- |
| `request.time` | `request.time < timestamp("2027-01-01T00:00:00Z")` |
| `request.ip` | `inIpRange(request.ip, "10.0.0.0/8")` |
| `request.mfa_age_seconds` | `request.mfa_age_seconds < 900` |
| `request.auth_method` | `request.auth_method == "saml"` |
| `resource.type`, `resource.name` | `resource.name.startsWith("prod-")` |
| `resource.tags` | `resource.tags["env"] == "prod"` (section 9.2) |
| `principal.type` | `principal.type == "service_account"` |

Expressions are validated when saved (unknown attributes and syntax errors are rejected) and have a maximum length.

---

## 9. Governance and guardrails

### 9.1 Organization policies

Guardrails that restrict what anyone can do, regardless of their roles (AWS service control policies, Google Cloud Organization Policy).

**`org_policy_constraints`** (platform catalog, seeded): `constraint` (primary key, for example `hub.allowedRegions`, `hub.requireMfa`, `hub.restrictSharingToDomains`, `compute.disableSerialPort`), `service`, `display_name`, `description`, `value_type` (`boolean` or `list`), `default_value` (`jsonb`), `created_at`. Services register their own constraints like permissions.

**`org_policies`**

| Column | Type | Notes |
| --- | --- | --- |
| `id`, `organization_id` | `uuid` | |
| `scope_type`, `scope_id` | `text`, `uuid` NOT NULL | `organization`, `folder`, or `project` |
| `constraint` | `text` NOT NULL | FK `org_policy_constraints` |
| `enforced` | `boolean` | For boolean constraints |
| `allowed_values`, `denied_values` | `text[]` | For list constraints |
| `inherit_from_parent` | `boolean` NOT NULL | Merge with the parent's policy, or replace it |
| `dry_run` | `boolean` NOT NULL | Log would-be violations without enforcing |
| standard columns | | including `version` |

Unique `(scope_type, scope_id, constraint)`.

### 9.2 Tags and labels

Two kinds, as in Google Cloud:

- **Tags** are governed: defined centrally, bound with permission, inherited down the hierarchy, and usable in conditions (section 8.5) and organization policies.
- **Labels** are free-form key/value pairs on projects and resources (`projects.labels`), used for cost reports only.

**`tag_keys`**: `id`, `organization_id`, `key` (unique per organization, lowercase), `description`, `purpose` (`general`, `access`, `cost`), standard columns.

**`tag_values`**: `id`, `organization_id`, `tag_key_id`, `value` (unique per key), `description`, standard columns.

**`tag_bindings`**: `id`, `organization_id`, `tag_value_id`, `scope_type`, `scope_id`, `created_*`. Unique `(scope_type, scope_id, tag_value_id)`. A scope has at most one value per key: a binding lower in the hierarchy overrides the inherited one.

### 9.3 Just-in-time access

Standing access is replaced by eligibility plus time-limited activation (Azure PIM, Google Cloud Privileged Access Manager).

**`access_entitlements`**: what a principal may request.

| Column | Type | Notes |
| --- | --- | --- |
| `id`, `organization_id` | `uuid` | |
| `scope_type`, `scope_id` | `text`, `uuid` | |
| `role_id` | `uuid` NOT NULL | |
| `eligible_principals` | `jsonb` NOT NULL | |
| `approvers` | `jsonb` NOT NULL | Principals who approve; empty means self-activation |
| `max_duration_seconds` | `integer` NOT NULL | |
| `require_justification` | `boolean` NOT NULL | |
| `require_mfa` | `boolean` NOT NULL | |
| standard columns | | including `version` |

**`access_requests`**: `id`, `organization_id`, `entitlement_id`, `requester_type`, `requester_id`, `justification`, `requested_duration_seconds`, `status` (`pending`, `approved`, `denied`, `active`, `expired`, `revoked`, `cancelled`), `decided_by`, `decided_at`, `decision_note`, `activated_at`, `expires_at`, `role_binding_id` (the temporary binding created on activation), `created_at`, `updated_at`.

### 9.4 Access reviews

Periodic recertification: reviewers confirm or remove each grant.

**`access_reviews`**: `id`, `organization_id`, `scope_type`, `scope_id`, `display_name`, `reviewers` (`jsonb`), `status` (`scheduled`, `in_progress`, `completed`, `cancelled`), `starts_at`, `due_at`, `completed_at`, `recurrence` (`none`, `quarterly`, `yearly`), `auto_remove_unreviewed` (boolean), standard columns.

**`access_review_items`**: `id`, `organization_id`, `review_id`, `role_binding_id`, snapshot of the grant (`principal_type`, `principal_id`, `role_id`, `scope_type`, `scope_id`), `decision` (`pending`, `keep`, `remove`), `decided_by`, `decided_at`, `note`, `created_at`.

---

## 10. Security posture

### 10.1 Organization security policy

**`organization_security_policies`** (one row per organization; folder and project overrides are **Decision needed D3**):

| Column | Type | Notes |
| --- | --- | --- |
| `organization_id` | `uuid` | Primary key |
| `mfa_required` | `boolean` NOT NULL | |
| `allowed_mfa_methods` | `text[]` NOT NULL | `totp`, `passkey` |
| `mfa_grace_period_days` | `integer` NOT NULL | Time new members have to enroll |
| `sso_required` | `boolean` NOT NULL | Password sign-in disabled for managed users |
| `break_glass_user_ids` | `uuid[]` NOT NULL | Owners exempt from `sso_required` |
| `session_max_age_seconds` | `integer` NOT NULL | |
| `session_idle_timeout_seconds` | `integer` NOT NULL | |
| `console_ip_allowlist` | `cidr[]` NOT NULL | Empty means no restriction |
| `password_min_length` | `integer` NOT NULL | |
| `password_history_depth` | `integer` NOT NULL | |
| `password_max_age_days` | `integer` | NULL means no expiry |
| `restrict_collaborators_to_domains` | `text[]` NOT NULL | Empty means any domain |
| standard columns | | including `version` |

### 10.2 Account recovery

**`user_recovery_methods`**: `id`, `user_id`, `method` (`email`, `phone`), `value` (lowercase email, or E.164 phone), `verified_at`, `last_used_at`, standard columns. Used only for recovery, never for sign-in.

### 10.3 Trusted devices

**`user_trusted_devices`**: `id`, `user_id`, `device_token_hash` (a long-lived random cookie, hashed), `display_name`, `user_agent`, `last_ip_address`, `trusted_until`, `last_seen_at`, `revoked_at`, `created_at`. A trusted device can skip MFA re-prompts within the organization's limits.

### 10.4 Sign-in risk

**`sign_in_events`** (append-only, partitioned monthly like `audit_logs`): `id`, `occurred_at`, `user_id` (NULL for unknown accounts), `email_attempted`, `outcome` (`success`, `bad_password`, `mfa_failed`, `locked`, `blocked_by_policy`), `auth_method`, `ip_address`, `country_code`, `asn`, `user_agent`, `risk_score` (`real`), `risk_reasons` (`text[]`: `new_country`, `impossible_travel`, `known_bad_ip`, …), `session_id`.

Kept separate from `audit_logs` because it is high-volume, has a shorter retention, and feeds risk scoring and the user's "recent activity" page. Live counters for lockout and rate limits stay in Redis.

---

## 11. Audit

### 11.1 Log types

`audit_logs` gains:

| Column | Type | Notes |
| --- | --- | --- |
| `log_type` | `text` NOT NULL | `admin_activity` (configuration changes; always on, can't be disabled), `data_access` (reads of sensitive data; per-organization opt-in), `system_event` (automatic actions), `policy_denied` (requests blocked by IAM or organization policy) |
| `service` | `text` NOT NULL | Emitting service (`hub`, `compute`, …) |
| `scope_type`, `scope_id` | `text`, `uuid` | Where it happened in the hierarchy |

Platform services write their audit events to Hub through the gRPC API, so each customer has one audit log across the whole cloud.

### 11.2 Retention and export

**`audit_settings`** (one row per organization): `organization_id`, `retention_days` (minimum 400 for `admin_activity`), `data_access_enabled_services` (`text[]`), `version`, standard columns.

**`audit_sinks`**: continuous export to customer-owned destinations.

| Column | Type | Notes |
| --- | --- | --- |
| `id`, `organization_id` | `uuid` | |
| `display_name` | `text` NOT NULL | |
| `destination_type` | `text` NOT NULL | `webhook`, `object_storage` |
| `destination_config` | `jsonb` NOT NULL | URL, bucket, and so on; secrets stored separately encrypted |
| `filter` | `text` | Expression selecting which events (section 8.5 language) |
| `status` | `text` NOT NULL | `active`, `disabled`, `failing` |
| `last_delivered_at`, `last_error` | | |
| standard columns | | |

Delivery progress is tracked through the event outbox (section 14.1).

### 11.3 Tamper evidence

A background job writes one digest per organization per hour, like AWS CloudTrail log file validation.

**`audit_digests`** (append-only)

| Column | Type | Notes |
| --- | --- | --- |
| `id` | `uuid` | |
| `organization_id` | `uuid` | NULL for events outside any organization |
| `period_start`, `period_end` | `timestamptz` NOT NULL | |
| `event_count` | `bigint` NOT NULL | |
| `events_hash` | `bytea` NOT NULL | SHA-256 over the period's events in `(occurred_at, id)` order |
| `previous_digest_hash` | `bytea` | Links digests into a chain |
| `digest_hash` | `bytea` NOT NULL | Hash of this row's contents |
| `signature` | `bytea` NOT NULL | Signed with a Hub signing key |
| `signing_key_id` | `text` NOT NULL | |
| `created_at` | | |

Anyone can recompute the hashes and verify the signatures, so altered or deleted events are detectable. This avoids per-row hash chains, which would serialize every audit write.

---

## 12. Services, subscriptions, and quotas

### 12.1 Service catalog

**`services`** (platform catalog): `id`, `name` (unique, for example `compute`), `display_name`, `description`, `status` (`preview`, `ga`, `deprecated`), `documentation_url`, `created_at`, `updated_at`. `permissions.service`, `org_policy_constraints.service`, and `audit_logs.service` refer to `services.name`.

### 12.2 Plans and entitlements

**`plans`**: `id`, `service_id` (NULL for platform-wide plans), `key` (unique per service), `display_name`, `description`, `status` (`active`, `retired`), `is_public`, `trial_days`, `created_at`, `updated_at`.

**`plan_entitlements`**: `plan_id`, `entitlement` (for example `compute.gpu.enabled`, `hub.sso.enabled`), `value` (`jsonb`: boolean, number, or list). Primary key `(plan_id, entitlement)`.

### 12.3 Subscriptions

**`subscriptions`**

| Column | Type | Notes |
| --- | --- | --- |
| `id`, `organization_id` | `uuid` | |
| `project_id` | `uuid` | NULL for organization-wide subscriptions |
| `service_id`, `plan_id` | `uuid` NOT NULL | |
| `billing_account_id` | `uuid` NOT NULL | |
| `status` | `text` NOT NULL | `trialing`, `active`, `past_due`, `cancel_scheduled`, `cancelled` |
| `trial_ends_at`, `current_period_start`, `current_period_end`, `cancel_at`, `cancelled_at` | `timestamptz` | |
| standard columns | | including `version` |

**`subscription_changes`** (append-only): `id`, `organization_id`, `subscription_id`, `from_plan_id`, `to_plan_id`, `effective_at`, `changed_by`, `reason`, `created_at`.

### 12.4 Quotas

**`quota_definitions`** (platform catalog, registered by services): `id`, `service_id`, `metric` (for example `compute.cpus`), `unit`, `scope_type` (`project` or `organization`), `display_name`, `default_limit` (`numeric`), `created_at`.

**`quota_overrides`**: `id`, `organization_id`, `quota_definition_id`, `scope_type`, `scope_id`, `limit` (`numeric`), `reason`, `granted_by` (a customer lowering their own limit, or a Hub operator raising it), `expires_at`, standard columns including `version`.

Services enforce quotas (they know current consumption) and ask Hub for the effective limit: override, else plan entitlement, else default.

---

## 13. Usage, cost, and billing

### 13.1 Usage

**`usage_records`** (append-only, partitioned monthly; **Decision needed D4**)

| Column | Type | Notes |
| --- | --- | --- |
| `id` | `uuid` | |
| `organization_id`, `project_id` | `uuid` NOT NULL | |
| `billing_account_id` | `uuid` NOT NULL | Resolved when recorded, so later moves don't rewrite history |
| `service` | `text` NOT NULL | |
| `metric` | `text` NOT NULL | For example `compute.cpu_seconds` |
| `quantity` | `numeric` NOT NULL | |
| `unit` | `text` NOT NULL | |
| `usage_start`, `usage_end` | `timestamptz` NOT NULL | |
| `region` | `text` | |
| `resource_type`, `resource_external_id` | `text` | |
| `labels` | `jsonb` NOT NULL | Copied from the project and resource for cost reports |
| `idempotency_key` | `text` NOT NULL | Supplied by the reporting service; duplicates are ignored |
| `received_at` | `timestamptz` NOT NULL | |

Unique `(service, idempotency_key, usage_start)` (the partition key must be part of unique keys).

**`usage_rollups`**: hourly and daily sums per `(billing_account_id, project_id, service, metric, region, period)`, written by a background job; reports read these, not raw records.

### 13.2 Billing accounts

Billing accounts are separate from projects, so one organization can have several (per department, or per currency) and many projects can share one.

**`billing_accounts`**

| Column | Type | Notes |
| --- | --- | --- |
| `id`, `organization_id` | `uuid` | |
| `display_name` | `text` NOT NULL | |
| `currency` | `text` NOT NULL | ISO 4217; fixed after creation |
| `status` | `text` NOT NULL | `active`, `past_due`, `suspended`, `closed` |
| `billing_email` | `text` NOT NULL | |
| `legal_name`, `tax_id` | `text` | |
| `address` | `jsonb` NOT NULL | Billing address |
| `payment_provider` | `text` | **Decision needed D5** |
| `payment_customer_ref` | `text` | The provider's customer ID; card data never touches Hub |
| standard columns | | including `version` |

Access to a billing account is granted with role bindings at `scope_type = 'billing_account'` (Billing Admin, Billing Viewer), like Google Cloud.

**`payment_methods`**: `id`, `organization_id`, `billing_account_id`, `provider_ref`, `kind` (`card`, `bank_transfer`, `invoice`), `display_hint` (for example `Visa •••• 4242`), `is_default`, `expires_at`, standard columns.

### 13.3 Prices

**`price_list_items`**: `id`, `service`, `metric`, `plan_id` (NULL for list price), `region` (NULL for all regions), `currency`, `unit_price_micros` (`bigint`; millionths of the currency's minor unit, because cloud unit prices are fractions of a cent), `tiers` (`jsonb`: volume tiers), `effective_from`, `effective_to`, `created_at`. Prices are never edited, only superseded by a new row with a later `effective_from`.

### 13.4 Invoices

**`invoices`**: `id`, `organization_id`, `billing_account_id`, `number` (unique, sequential per billing account), `period_start`, `period_end`, `currency`, `subtotal`, `credits_applied`, `tax`, `total` (all `bigint` minor units), `status` (`draft`, `finalized`, `paid`, `void`, `uncollectible`), `finalized_at`, `due_at`, `paid_at`, `pdf_object_key`, standard columns.

**`invoice_line_items`**: `id`, `organization_id`, `invoice_id`, `project_id`, `service`, `metric`, `description`, `quantity` (`numeric`), `unit_price_micros`, `amount` (`bigint`), `created_at`. Finalized invoices are never changed; corrections are credit notes.

### 13.5 Credits and adjustments

**`credits`**: `id`, `organization_id`, `billing_account_id`, `kind` (`promotional`, `goodwill`, `refund`, `credit_note`), `amount`, `currency`, `remaining`, `expires_at`, `reason`, `granted_by`, `created_at`, `updated_at`.

### 13.6 Budgets

**`budgets`**: `id`, `organization_id`, `billing_account_id`, `display_name`, `amount`, `currency`, `period` (`monthly`, `quarterly`, `yearly`), `scope_filter` (`jsonb`: projects, services, labels), `thresholds` (`integer[]`, percentages, for example `{50,90,100}`), `notify_principals` (`jsonb`), `hard_limit` (boolean: tell services to stop provisioning), standard columns including `version`.

**`budget_alerts`** (append-only): `id`, `organization_id`, `budget_id`, `period_start`, `threshold`, `actual_amount`, `forecast_amount`, `notified_at`. One row per threshold per period, so each alert is sent once.

---

## 14. Platform plumbing

### 14.1 Event outbox

Other services must learn about identity changes immediately (a deactivated user must lose access everywhere). Events are written in the same transaction as the change and delivered afterwards, so none are lost.

**`event_outbox`**

| Column | Type | Notes |
| --- | --- | --- |
| `id` | `uuid` | UUIDv7: time-ordered, so consumers read in order |
| `organization_id` | `uuid` | |
| `event_type` | `text` NOT NULL | `hub.user.deactivated`, `hub.role_binding.deleted`, `hub.project.deleted`, … |
| `subject_type`, `subject_id` | `text`, `uuid` | |
| `payload` | `jsonb` NOT NULL | No secrets |
| `created_at` | `timestamptz` NOT NULL | |
| `published_at` | `timestamptz` | Set once delivered to the message stream |

Services consume events through a gRPC streaming call (and later webhooks). Published rows are deleted after 7 days.

**`webhook_endpoints`** and **`webhook_deliveries`** (later; both carry `organization_id`): customer-registered URLs for organization events, with a signing secret (encrypted), retries, and delivery history.

### 14.2 Organization contacts

**`organization_contacts`**: `id`, `organization_id`, `category` (`security`, `billing`, `technical`, `legal`, `product_updates`), `email` (lowercase), `language`, `verified_at`, standard columns. Hub and platform services send category-specific notifications here instead of guessing from owners.

### 14.3 Idempotency keys

**`idempotency_keys`**: `organization_id`, `principal_id`, `key` (client-supplied `Idempotency-Key` header), `request_hash` (`bytea`: a replay with a different body is rejected), `response_status`, `response_body` (`jsonb`), `created_at`, `expires_at`. Primary key `(organization_id, principal_id, key)`. Used for money-moving and create operations; expired rows are purged daily. Short-lived keys for other endpoints can live in Redis.

### 14.4 Regions and data residency

**`regions`** (platform catalog, seeded): `code` (primary key, for example `in-south-1`), `display_name`, `jurisdiction` (for example `IN`, `EU`), `status` (`preview`, `available`, `retired`), `created_at`.

- `organizations.data_residency` (`text[]`): jurisdictions the organization's data must stay in; empty means no restriction.
- `projects.region_policy` (section 4.2): allowed regions, narrowed further by the `hub.allowedRegions` organization policy (section 9.1).
- Hub's own data (identities, audit) is stored in the Hub deployment's home region; its location is shown to customers.

### 14.5 Transactional email

**`email_outbox`**: `id`, `organization_id` (NULL for account email), `to_email`, `template`, `template_data` (`jsonb`, no secrets; links carry tokens that are generated at send time), `status` (`pending`, `sent`, `failed`), `attempts`, `last_error`, `created_at`, `sent_at`. Written in the same transaction as the event that needs the email (invitation, password reset), sent by a background job, so an email is never lost or sent for a rolled-back change.

---

## 15. Row-Level Security by table

| Policy class | Rule | Tables |
| --- | --- | --- |
| Tenant | `organization_id` = current org | `folders`, `projects`, `hierarchy_paths`, `resources`, `groups`, `group_members`, `service_accounts`, `service_account_keys`, `federated_credentials`, `api_keys`, `organization_invitations`, `organization_domains`, `saml_connections`, `saml_certificates`, `scim_tokens`, `role_bindings`, `deny_policies`, `deny_rules`, `org_policies`, `tag_keys`, `tag_values`, `tag_bindings`, `access_entitlements`, `access_requests`, `access_reviews`, `access_review_items`, `organization_security_policies`, `audit_settings`, `audit_sinks`, `subscriptions`, `subscription_changes`, `quota_overrides`, `usage_records`, `usage_rollups`, `billing_accounts`, `payment_methods`, `invoices`, `invoice_line_items`, `credits`, `budgets`, `budget_alerts`, `organization_contacts`, `idempotency_keys`, `webhook_endpoints`, `webhook_deliveries` |
| Tenant + member | Current org, or the current user's own row | `organization_collaborators`, `external_identities` |
| Both sides | Either organization in the request, or the user | `home_org_transfer_requests` |
| User-owned | `user_id` = current user | `user_email_history`, `user_consents`, `user_recovery_methods`, `user_trusted_devices` (plus batch 1's `user_*` tables) |
| Audit-like | Current org, or the current user's own org-less rows; insert only | `sign_in_events`, `audit_digests` (read only) |
| Mixed catalog | System rows readable everywhere; custom rows by org | `roles`, `role_permissions` |
| Platform catalog | No RLS; the app role may only read; written through the platform role | `permissions`, `services`, `plans`, `plan_entitlements`, `price_list_items`, `quota_definitions`, `org_policy_constraints`, `regions`, `public_email_domains`, `oauth_clients` |
| Platform private | No RLS; no privileges for the app role at all; used only through the platform role | `signing_keys`, `oauth_client_secrets` |
| Insert-only outbox | The app role may insert rows for the current org (or org-less rows) and never read, update, or delete them; background jobs read and mark them through the platform role | `event_outbox`, `email_outbox` |
| Token lookups | Owner policy plus a read-only lookup key | `oauth_refresh_tokens` (`app.lookup_refresh_token_hash`), `scim_tokens` and `service_account_keys` and `api_keys` (lookup by hash for authentication) |

Every table with `organization_id` or `user_id` is covered; an automated test will enforce it once test infrastructure exists.

---

## 16. Build order

Each batch is a small number of migrations (one per area, not one per table), written from this document and reviewed together.

| Batch | Contents | Unblocks |
| --- | --- | --- |
| 1 (done) | `audit_logs`, `organizations`, `users` and credentials, `authz` core | Sign-up, login, MFA, basic roles |
| **2** | Resource hierarchy (section 4), groups (section 5.3), service accounts and keys (section 5.4), collaborators, invitations, domains, transfers (section 6), role bindings rework (section 8.3), permission and role additions (section 8.2), organization security policy (section 10.1), audit log types (section 11.1), event outbox (section 14.1), organization contacts (section 14.2), regions and residency (section 14.4), email outbox (section 14.5), user history tables (section 5.2), standard columns on existing tables (section 3.2) | Projects, teams, machine access, real authorization, onboarding |
| 3 | SAML, external identities, SCIM (section 7.3), OAuth clients, refresh tokens, signing keys (section 7.4), recovery methods, trusted devices, sign-in events (sections 10.2–10.4), federated credentials (section 5.4), API keys (section 5.5) | Enterprise SSO, platform sign-in |
| 4 | Deny policies (section 8.4), conditions (section 8.5), organization policies (section 9.1), tags (section 9.2), just-in-time access (section 9.3), access reviews (section 9.4) | Enterprise governance |
| 5 | Service catalog, plans, subscriptions, quotas (section 12), usage, prices, billing accounts, invoices, credits, budgets (section 13), idempotency keys (section 14.3), audit settings, sinks, digests (sections 11.2 and 11.3) | Commercial platform |

**Changes to batch 1 (Decision needed D6):** batch 2 reworks `role_bindings` and adds columns to existing tables. While Hub is only in local development, the batch 1 migrations can be edited in place and re-applied (`make migrate-revert` back to zero, then `make migrate`), keeping the migration count low. Once any shared environment exists, changes must be new migrations only.

---

## 17. Decisions needed

| # | Decision | Recommendation |
| --- | --- | --- |
| D1 | Resource hierarchy | Organization → Folders (optional, nestable, max depth 10) → Projects → Resources (section 4) |
| D2 | Condition expression language | CEL with a fixed attribute set (section 8.5) |
| D3 | Security policy overrides below the organization | Organization-level only at first; add folder and project overrides only when customers need them |
| D4 | Partition management for tables other than `audit_logs` | Generalize the existing exception into one function, `ensure_monthly_partitions(table, months_ahead)`, limited to an allowlist (`audit_logs`, `sign_in_events`, `usage_records`) |
| D5 | Payment provider | Deferred; the schema only stores the provider name and opaque references |
| D6 | How batch 2 changes batch 1 tables | Edit batch 1 in place while only local development exists; new migrations only after that |
