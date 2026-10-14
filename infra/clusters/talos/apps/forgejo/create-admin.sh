#!/usr/bin/env bash
# Create the first Forgejo admin user from the out-of-band `forgejo-admin`
# Secret (infra/clusters/talos/apps/secrets/forgejo-admin.sops.yaml).
#
# One-time: run after the `forgejo` Deployment is Ready. Forgejo is deployed
# with INSTALL_LOCK=true and DISABLE_REGISTRATION=true, so there is NO default
# account and no web sign-up -- this is how the first (admin) login is created.
#
#   # fill in username/password/email once:
#   sops infra/clusters/talos/apps/secrets/forgejo-admin.sops.yaml
#   # then create the admin:
#   bash infra/clusters/talos/apps/forgejo/create-admin.sh
#
# Override the cluster/namespace with CTX / NS if needed.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
CTX="${CTX:-talos}"
NS="${NS:-forgejo}"
SECRET="$DIR/../secrets/forgejo-admin.sops.yaml"

[ -f "$SECRET" ] || { echo "missing $SECRET (create it with sops)" >&2; exit 1; }

plain="$(sops -d "$SECRET")"
value_of() {
  printf '%s\n' "$plain" \
    | sed -n "s/^[[:space:]]*$1:[[:space:]]*//p" \
    | head -n1 | tr -d '"'
}
username="$(value_of username)"
password="$(value_of password)"
email="$(value_of email)"

for k in username password email; do
  v="$(value_of "$k")"
  case "$v" in ""|PASTE_*) echo "fill in '$k' in $SECRET first" >&2; exit 1;; esac
done

echo "-> creating admin '$username' in $CTX/$NS"
kubectl --context "$CTX" -n "$NS" exec deploy/forgejo -- \
  forgejo admin user create --admin \
    --username "$username" \
    --password "$password" \
    --email "$email" \
    --must-change-password=false

echo "-> done. Log in at http://git.homelab.local/ as '$username'."
