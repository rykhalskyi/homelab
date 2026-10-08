#!/usr/bin/env bash
# Provision the `pullini` role and database on the cluster's standalone
# PostgreSQL (infra/clusters/k8s/apps/postgresql). Idempotent: safe to re-run, and it
# resets the role password to whatever `DATABASE_URL` currently holds, so a
# migrated/rebuilt cluster is recovered by recreating `pullini-secrets` and
# running this script.
#
# The app's DSN (including the password) lives only in the `pullini-secrets`
# Secret, created out of band -- never in Git. This script reads it from there
# and talks to Postgres using the existing superuser credential in
# `nextcloud-db` (key `postgres-password`).
#
# Usage:
#   bash infra/clusters/k8s/apps/pullini/provision-db.sh
#
# Overridable via env: NAMESPACE, APP_SECRET, PG_POD, PG_SECRET_NAME,
# PG_ADMIN_USER, PG_ADMIN_PASSWORD_KEY, DJANGO_DB_URL_KEY.
set -euo pipefail

NAMESPACE="${NAMESPACE:-homelab}"
APP_SECRET="${APP_SECRET:-pullini-secrets}"
DJANGO_DB_URL_KEY="${DJANGO_DB_URL_KEY:-DATABASE_URL}"
PG_POD="${PG_POD:-postgresql-0}"
PG_SECRET_NAME="${PG_SECRET_NAME:-nextcloud-db}"
PG_ADMIN_USER="${PG_ADMIN_USER:-postgres}"
PG_ADMIN_PASSWORD_KEY="${PG_ADMIN_PASSWORD_KEY:-postgres-password}"

command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 not found" >&2; exit 1; }

echo "Reading ${DJANGO_DB_URL_KEY} from secret ${NAMESPACE}/${APP_SECRET}..." >&2
DATABASE_URL="$(kubectl -n "$NAMESPACE" get secret "$APP_SECRET" \
  -o "jsonpath={.data.${DJANGO_DB_URL_KEY}}" | base64 -d)"
[ -n "$DATABASE_URL" ] || { echo "secret key ${DJANGO_DB_URL_KEY} is empty" >&2; exit 1; }

read_field() {
  PULLINI_DB_URL="$DATABASE_URL" python3 - "$1" <<'PY'
import os, sys
from urllib.parse import unquote, urlsplit

u = urlsplit(os.environ["PULLINI_DB_URL"])
fields = {
    "user": unquote(u.username or ""),
    "password": unquote(u.password or ""),
    "host": u.hostname or "",
    "port": str(u.port or 5432),
    "dbname": (u.path or "").lstrip("/"),
}
sys.stdout.write(fields[sys.argv[1]])
PY
}

DB_USER="$(read_field user)"
DB_PASS="$(read_field password)"
DB_NAME="$(read_field dbname)"
[ -n "$DB_USER" ] && [ -n "$DB_PASS" ] && [ -n "$DB_NAME" ] \
  || { echo "DATABASE_URL is missing user, password, or database name" >&2; exit 1; }

echo "Provisioning role '${DB_USER}' and database '${DB_NAME}' on ${PG_POD}..." >&2
PG_ADMIN_PASSWORD="$(kubectl -n "$NAMESPACE" get secret "$PG_SECRET_NAME" \
  -o "jsonpath={.data.${PG_ADMIN_PASSWORD_KEY}}" | base64 -d)"
[ -n "$PG_ADMIN_PASSWORD" ] \
  || { echo "could not read ${PG_SECRET_NAME}/${PG_ADMIN_PASSWORD_KEY}" >&2; exit 1; }

kubectl -n "$NAMESPACE" exec -i "$PG_POD" -- \
  env PGPASSWORD="$PG_ADMIN_PASSWORD" \
  psql -v ON_ERROR_STOP=1 -U "$PG_ADMIN_USER" -d postgres \
    -v role="$DB_USER" -v pw="$DB_PASS" -v db="$DB_NAME" <<'SQL'
-- Create the role if missing, then always (re)set its password to the DSN's.
SELECT format('CREATE ROLE %I', :'role')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'role')\gexec
SELECT format('ALTER ROLE %I WITH LOGIN PASSWORD %L', :'role', :'pw')\gexec
-- Create the database, owned by the role, if missing.
SELECT format('CREATE DATABASE %I OWNER %I', :'db', :'role')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'db')\gexec
SQL

echo "Done. ${DB_USER}@${DB_NAME} is ready." >&2
