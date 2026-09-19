#!/usr/bin/env bash
#
# Install or update the byebyemoneylist Nextcloud app inside the running
# Nextcloud AIO container (nextcloud-aio-nextcloud).
#
# The app is not baked into a Nextcloud image - AIO pins the image to
# ghcr.io/nextcloud-releases/aio-nextcloud and does not allow an override.
# Instead we sideload the app as a custom app: /var/www/html/custom_apps is on
# the persistent nextcloud_aio_nextcloud volume (and is excluded from AIO's
# upgrade rsync), so files placed there survive restarts and Nextcloud updates.
#
# The artifact comes from a pinned GitHub release published by the app repo's
# release workflow (frontend built on CI; no Node/npm needed on the server).
#
# Usage:
#   infra/nextcloud/deploy-app.sh
#   infra/nextcloud/deploy-app.sh --version 1.0.3
#
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=versions.env
source "${script_dir}/versions.env"

app_id="byebyemoneylist"
app_repo="${BYML_REPO:-rykhalskyi/byebyemoneylist-ns}"
nc_container="${NC_CONTAINER:-nextcloud-aio-nextcloud}"
app_dir="/var/www/html/custom_apps/${app_id}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --version) BYML_VERSION="${2:?--version requires a value}"; shift 2 ;;
    -h|--help) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | grep -v '^set -euo' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "${BYML_VERSION:-}" ] || die "BYML_VERSION is not set (see versions.env)"
command -v docker >/dev/null 2>&1 || die "docker not found"
docker inspect "$nc_container" >/dev/null 2>&1 \
  || die "container '$nc_container' not found - is the Nextcloud AIO stack running?"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

tarball="${app_id}-${BYML_VERSION}.tar.gz"
url="https://github.com/${app_repo}/releases/download/v${BYML_VERSION}/${tarball}"

log "downloading ${url}"
curl -fsSL --retry 3 --retry-delay 2 -o "${tmp}/${tarball}" "$url" \
  || die "download failed - does release v${BYML_VERSION} exist?"

if [ -n "${BYML_SHA256:-}" ]; then
  log "verifying sha256"
  printf '%s  %s\n' "$BYML_SHA256" "${tmp}/${tarball}" | sha256sum -c - >/dev/null \
    || die "sha256 mismatch for ${tarball}"
else
  log "BYML_SHA256 is empty - skipping checksum verification"
fi

log "extracting and validating"
tar -C "$tmp" -xzf "${tmp}/${tarball}"
[ -f "${tmp}/${app_id}/appinfo/info.xml" ] \
  || die "unexpected tarball layout (missing ${app_id}/appinfo/info.xml)"
tar_version="$(grep -oP '(?<=<version>)[^<]+' "${tmp}/${app_id}/appinfo/info.xml")"
[ "$tar_version" = "$BYML_VERSION" ] \
  || die "tarball app version '${tar_version}' does not match '${BYML_VERSION}'"

log "copying app into container ${nc_container}"
docker exec "$nc_container" rm -rf "/var/www/html/custom_apps/${app_id}.new"
docker cp "${tmp}/${app_id}" "${nc_container}:/var/www/html/custom_apps/${app_id}.new"
docker exec "$nc_container" chown -R 33:0 "/var/www/html/custom_apps/${app_id}.new"

log "activating (disable -> swap -> enable, migrations)"
docker exec -u www-data "$nc_container" php occ app:disable "$app_id" >/dev/null 2>&1 || true
docker exec "$nc_container" sh -c "
  set -e
  rm -rf '${app_dir}'
  mv '/var/www/html/custom_apps/${app_id}.new' '${app_dir}'
  chown -R 33:0 '${app_dir}'
"
docker exec -u www-data "$nc_container" php occ app:enable "$app_id"
docker exec -u www-data "$nc_container" php occ app:update "$app_id" || true
docker exec -u www-data "$nc_container" php occ migrations:migrate "$app_id"

log "status"
docker exec -u www-data "$nc_container" php occ app:list | grep -i "$app_id" || true
docker exec -u www-data "$nc_container" php occ migrations:status "$app_id" || true

log "done: ${app_id} v${BYML_VERSION} deployed to ${nc_container}"
