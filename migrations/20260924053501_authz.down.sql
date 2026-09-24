-- Reverts 20260924053501_authz.up.sql. The seed data is dropped with its tables.

DROP TABLE IF EXISTS role_bindings;
DROP TABLE IF EXISTS role_permissions;
DROP TABLE IF EXISTS roles;
DROP TABLE IF EXISTS permissions;
