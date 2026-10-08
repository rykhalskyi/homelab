#!/usr/bin/env bash
# Clear Nextcloud's brute-force / login rate-limit state on k3s.
#
# Why this exists: Nextcloud 35 stores brute-force attempts in the distributed
# cache (Redis) via `OC\Security\Bruteforce\Backend\MemoryCacheBackend`, keyed
# by IP *subnet* -- not in the `oc_bruteforce_attempts` database table. Behind
# the Cloudflare tunnel every device on the home network shares the same public
# IPv6 /64, so a single client retrying a stale password (typically the mobile
# app) fills the shared bucket and throttles the whole house with HTTP 429
# ("too many requests"), even when the password is correct.
#
# `occ security:bruteforce:reset <ip>` only clears one address and leaves the
# subnet bucket in place, so this removes the backend keys directly.
#
# Usage:
#   bash infra/clusters/k8s/apps/nextcloud/reset-bruteforce.sh
#
# Overridable via env: NAMESPACE, REDIS_POD, REDIS_PASSWORD_FILE.
set -euo pipefail

NAMESPACE="${NAMESPACE:-homelab}"
REDIS_PASSWORD_FILE="${REDIS_PASSWORD_FILE:-/opt/bitnami/redis/secrets/redis-password}"

command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }

if [ -z "${REDIS_POD:-}" ]; then
  REDIS_POD="$(kubectl -n "$NAMESPACE" get pod \
    -l 'app.kubernetes.io/instance=nextcloud,app.kubernetes.io/name=redis,app.kubernetes.io/component=master' \
    -o name | head -n1)"
fi
[ -n "$REDIS_POD" ] || { echo "no Nextcloud redis pod found in ${NAMESPACE}" >&2; exit 1; }

echo "Clearing brute-force keys on ${NAMESPACE}/${REDIS_POD##*/}..." >&2

kubectl -n "$NAMESPACE" exec "$REDIS_POD" -- sh -c '
  PW_FILE="'"$REDIS_PASSWORD_FILE"'"
  if [ -r "$PW_FILE" ]; then
    set -- -a "$(cat "$PW_FILE")" --no-auth-warning
  else
    set --
  fi

  before=$(redis-cli "$@" --scan --pattern "*MemoryCacheBackend*" 2>/dev/null | wc -l)
  redis-cli "$@" --scan --pattern "*MemoryCacheBackend*" 2>/dev/null \
    | while IFS= read -r key; do redis-cli "$@" DEL "$key" >/dev/null; done
  after=$(redis-cli "$@" --scan --pattern "*MemoryCacheBackend*" 2>/dev/null | wc -l)

  echo "brute-force keys: before=${before} after=${after}"
'
