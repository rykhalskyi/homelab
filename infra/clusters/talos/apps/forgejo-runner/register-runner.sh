#!/usr/bin/env bash
# Register the talos Forgejo Actions runner with Forgejo, using the offline
# (Infrastructure-as-Code) registration path so the token stays out of the
# Forgejo UI and out of Git.
#
# Run once, AFTER the `forgejo` Deployment is Ready. It:
#   1. generates a 40-char hex secret,
#   2. registers the runner inside the forgejo pod (global scope by default),
#   3. prints the UUID + secret to paste into:
#        - configmap.yaml          -> server.connections.otakeessen.uuid
#        - the SOPS Secret          apps/secrets/forgejo-runner-token.sops.yaml (key: token)
#
#   bash infra/clusters/talos/apps/forgejo-runner/register-runner.sh
#
# Override with CTX / NS / NAME / SCOPE.
set -euo pipefail

CTX="${CTX:-talos}"
NS="${NS:-forgejo}"
NAME="${NAME:-talos}"
# Empty scope => global runner (all repositories). Use "owner" or "owner/repo"
# to scope it down.
SCOPE="${SCOPE:-}"

secret="$(openssl rand -hex 20)"   # 40 hex chars, as the CLI requires

args=(forgejo-cli actions register --name "$NAME" --secret "$secret")
[ -n "$SCOPE" ] && args+=(--scope "$SCOPE")

echo "-> registering runner '$NAME' in $CTX/$NS (scope: ${SCOPE:-global})"
# The Forgejo CLI refuses to run as root; the pod runs as root by default, so
# drop to the `git` user (uid 1000) with s6-setuidgid first.
uuid="$(kubectl --context "$CTX" -n "$NS" exec deploy/forgejo -- \
  s6-setuidgid git "${args[@]}" | tr -d '\r' | tail -n1)"

echo
echo "  UUID   : $uuid"
echo "  SECRET : $secret"
echo
echo "Next:"
echo "  1. put the UUID in infra/clusters/talos/apps/forgejo-runner/configmap.yaml"
echo "     (server.connections.otakeessen.uuid)"
echo "  2. create the token Secret and apply it out of band:"
echo "       sops infra/clusters/talos/apps/secrets/forgejo-runner-token.sops.yaml"
echo "       bash infra/clusters/talos/apps/secrets/apply.sh"
