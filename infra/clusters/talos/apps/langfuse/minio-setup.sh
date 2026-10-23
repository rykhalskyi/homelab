#!/usr/bin/env bash
# MinIO helper for the Langfuse deployment.
#
# Run this on the Synology NAS where MinIO listens on 127.0.0.1:9000.
# It does not contain credentials: point it at the env file that holds the
# MinIO root user/password, or export the variables yourself.
#
#   MINIO_ENV=/volume1/docker/minio.env ./minio-langfuse.sh verify
#   MINIO_ENV=/volume1/docker/minio.env ./minio-langfuse.sh setup
#   MINIO_ENV=/volume1/docker/minio.env ./minio-langfuse.sh create-service-account
#
# Environment:
#   MINIO_ENV         env file to source (default: ./minio.env if it exists)
#   MC_BIN            mc binary (default: /volume1/docker/bin/mc, then PATH)
#   MC_CONFIG_DIR     writable config dir; Synology has no usable $HOME for mc
#   MINIO_ENDPOINT    default http://127.0.0.1:9000
#   MINIO_ALIAS       default local
#
# The `setup` command is idempotent and does NOT rotate the existing
# service-account keys. `create-service-account` creates new keys; if you use
# it, also update s3-access-key / s3-secret-key in the SOPS Secret.
set -euo pipefail

MC_BIN="${MC_BIN:-/volume1/docker/bin/mc}"
if [[ ! -x "$MC_BIN" ]]; then
  MC_BIN="$(command -v mc || true)"
fi
if [[ -z "$MC_BIN" || ! -x "$MC_BIN" ]] || ! "$MC_BIN" --version 2>/dev/null | grep -q 'mc version'; then
  echo "MinIO mc not found (or found GNU Midnight Commander); set MC_BIN to the downloaded mc binary" >&2
  exit 1
fi

export MC_CONFIG_DIR="${MC_CONFIG_DIR:-/tmp/mc}"
mkdir -p "$MC_CONFIG_DIR"

MINIO_ENV="${MINIO_ENV:-./minio.env}"
if [[ -f "$MINIO_ENV" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "$MINIO_ENV"
  set +a
fi

MINIO_USER="${MINIO_ROOT_USER:-${MINIO_USER:-}}"
MINIO_PASSWORD="${MINIO_ROOT_PASSWORD:-${MINIO_PASSWORD:-}}"
if [[ -z "$MINIO_USER" || -z "$MINIO_PASSWORD" ]]; then
  echo "set MINIO_ROOT_USER/MINIO_ROOT_PASSWORD (or source MINIO_ENV)" >&2
  exit 1
fi
MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://127.0.0.1:9000}"
MINIO_ALIAS="${MINIO_ALIAS:-local}"

mc_alias() {
  "$MC_BIN" alias set "$MINIO_ALIAS" "$MINIO_ENDPOINT" "$MINIO_USER" "$MINIO_PASSWORD" >/dev/null
}

write_policy() {
  local policy="$MC_CONFIG_DIR/langfuse-policy.json"
  cat > "$policy" <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetBucketLocation", "s3:ListBucket"],
      "Resource": ["arn:aws:s3:::langfuse", "arn:aws:s3:::clickhouse-backups"]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:AbortMultipartUpload", "s3:DeleteObject", "s3:GetObject", "s3:ListMultipartUploadParts", "s3:PutObject"],
      "Resource": ["arn:aws:s3:::langfuse/*", "arn:aws:s3:::clickhouse-backups/langfuse/*"]
    }
  ]
}
JSON
  printf '%s\n' "$policy"
}

cmd_verify() {
  mc_alias
  echo "== buckets"
  "$MC_BIN" ls "$MINIO_ALIAS"
  echo "== policy langfuse-rw"
  "$MC_BIN" admin policy info "$MINIO_ALIAS" langfuse-rw
  echo "== user langfuse"
  "$MC_BIN" admin user info "$MINIO_ALIAS" langfuse
  echo "== service accounts (access keys only; secrets stay in SOPS)"
  "$MC_BIN" admin user svcacct ls "$MINIO_ALIAS" langfuse
  echo "== clickhouse-backups lifecycle"
  "$MC_BIN" ilm rule ls "$MINIO_ALIAS/clickhouse-backups" || true
}

cmd_setup() {
  mc_alias
  "$MC_BIN" mb --ignore-existing "$MINIO_ALIAS/langfuse"
  "$MC_BIN" mb --ignore-existing "$MINIO_ALIAS/clickhouse-backups"

  local policy
  policy="$(write_policy)"
  "$MC_BIN" admin policy create "$MINIO_ALIAS" langfuse-rw "$policy"

  if ! "$MC_BIN" admin user info "$MINIO_ALIAS" langfuse >/dev/null 2>&1; then
    "$MC_BIN" admin user add "$MINIO_ALIAS" langfuse "$(openssl rand -hex 24)"
    echo "created user langfuse"
  else
    echo "user langfuse already exists (password unchanged)"
  fi

  "$MC_BIN" admin policy attach "$MINIO_ALIAS" langfuse-rw --user langfuse

  if ! "$MC_BIN" ilm rule add --prefix "langfuse/" --expire-days 30 "$MINIO_ALIAS/clickhouse-backups" >/dev/null 2>&1; then
    echo "lifecycle rule already present (or could not be added)"
  fi

  echo "buckets, policy and user are ready; existing service-account keys were not changed"
}

cmd_create_service_account() {
  mc_alias
  "$MC_BIN" admin user svcacct add "$MINIO_ALIAS" langfuse --name langfuse-langfuse
  echo
  echo "Now update s3-access-key / s3-secret-key in"
  echo "infra/clusters/talos/apps/secrets/langfuse-secrets.sops.yaml and re-apply it."
}

case "${1:-verify}" in
  verify)
    cmd_verify
    ;;
  setup)
    cmd_setup
    ;;
  create-service-account)
    cmd_create_service_account
    ;;
  *)
    sed -n '2,24p' "$0"
    exit 2
    ;;
esac
