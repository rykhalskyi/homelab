#!/usr/bin/env bash
#
# Deploy the pinned laya-api container image on node-one.
#
# The image is built and pushed to GHCR by the release workflow in
# rykhalskyi/laya-api. LAYA_API_VERSION and LAYA_API_SHA256 (the image digest)
# are pinned in versions.env and match a published GitHub release, so the exact
# image is always deployed and can be rolled back by editing two lines.
#
# Usage:
#   infra/laya-api/deploy.sh
#   infra/laya-api/deploy.sh --pin [--version 0.1.0]   # pin version + digest into versions.env
#
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
versions_file="${script_dir}/versions.env"
env_file="${script_dir}/.env"
compose_file="${script_dir}/docker-compose.yml"

image_repo="${LAYA_API_IMAGE:-ghcr.io/rykhalskyi/laya-api}"
app_repo="${LAYA_API_REPO:-rykhalskyi/laya-api}"

# shellcheck source=versions.env
source "$versions_file"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

set_env_var() {
  local key="$1" value="$2"
  if grep -q "^${key}=" "$versions_file"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$versions_file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$versions_file"
  fi
}

do_pin=0
while [ $# -gt 0 ]; do
  case "$1" in
    --version) LAYA_API_VERSION="${2:?--version requires a value}"; shift 2 ;;
    --pin) do_pin=1; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | grep -v '^set -euo' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "${LAYA_API_VERSION:-}" ] || die "LAYA_API_VERSION is not set (see versions.env)"

# --pin: fetch the checksum (image digest) asset from the release and write both
# fields into versions.env, so the pinned version and its digest stay in sync.
if [ "$do_pin" = 1 ]; then
  asset="laya-api-${LAYA_API_VERSION}.digest"
  url="https://github.com/${app_repo}/releases/download/v${LAYA_API_VERSION}/${asset}"
  log "fetching digest for v${LAYA_API_VERSION}"
  digest="$(curl -fsSL --retry 3 --retry-delay 2 "$url" | tr -d '[:space:]')" \
    || die "could not fetch ${url} - does release v${LAYA_API_VERSION} exist?"
  case "$digest" in
    sha256:*) ;;
    *) die "unexpected digest '${digest}' in release asset ${asset}" ;;
  esac
  set_env_var LAYA_API_VERSION "$LAYA_API_VERSION"
  set_env_var LAYA_API_SHA256 "$digest"
  log "pinned LAYA_API_VERSION=${LAYA_API_VERSION} and LAYA_API_SHA256=${digest} in versions.env (commit it)"
  exit 0
fi

command -v docker >/dev/null 2>&1 || die "docker not found"
[ -f "$compose_file" ] || die "missing ${compose_file}"
[ -f "$env_file" ] || die "missing ${env_file} - copy .env.example to .env and set LAYA_ADMIN_KEY"
[ -n "${LAYA_API_SHA256:-}" ] || die "LAYA_API_SHA256 is empty - run with --pin (see infra/laya-api/README.md)"

# Export the pinned tag/digest and the .env secrets for Compose substitution.
set -a
# shellcheck source=versions.env
source "$versions_file"
# shellcheck source=.env
source "$env_file"
set +a

log "deploying ${image_repo}:${LAYA_API_VERSION}@${LAYA_API_SHA256}"
docker compose -f "$compose_file" pull
docker compose -f "$compose_file" up -d

log "status"
docker compose -f "$compose_file" ps
