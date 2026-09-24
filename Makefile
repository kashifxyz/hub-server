.DEFAULT_GOAL := help
SHELL := /bin/bash

MIGRATIONS_DIR := migrations

# Migrations run as the database owner (hubownerusr), never as the runtime
# roles. The connection comes from DATABASE_OWNER_URL: an environment variable
# or `make ... DATABASE_OWNER_URL=...` wins; otherwise it is read from .env.
# .env is loaded by the shell (not make's include), so quoting works the same
# way it does for the server: wrap values containing `$` in single quotes.
define with_owner_url
	@if [ -z "$$DATABASE_OWNER_URL" ] && [ -f .env ]; then \
		set -a; . ./.env; set +a; \
	fi; \
	if [ -z "$$DATABASE_OWNER_URL" ]; then \
		echo "error: DATABASE_OWNER_URL is not set (add it to .env, see .env.example)" >&2; \
		exit 1; \
	fi; \
	if ! command -v sqlx >/dev/null 2>&1; then \
		echo "error: sqlx-cli is not installed (cargo install sqlx-cli --no-default-features --features postgres,rustls)" >&2; \
		exit 1; \
	fi; \
	$(1)
endef

.PHONY: help migrate migrate-revert

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*## "; printf "Usage: make <target>\n\n"} /^[a-zA-Z_-]+:.*## / { printf "  %-16s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

migrate: ## Apply all pending migrations
	$(call with_owner_url,sqlx migrate run --source $(MIGRATIONS_DIR) --database-url "$$DATABASE_OWNER_URL")

migrate-revert: ## Revert the most recently applied migration
	$(call with_owner_url,sqlx migrate revert --source $(MIGRATIONS_DIR) --database-url "$$DATABASE_OWNER_URL")
