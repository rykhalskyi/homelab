---
tags: [backup, restore, disaster-recovery, postgres, nextcloud, k3s, flux, secrets, sops]
date: 2026-10-02
source_count: 0
---

# Backups: what to save and how to restore

> **Why this page exists.** On 2026-10-02 a bad GitOps change made Flux prune its
> own root Kustomization, which then garbage-collected the whole `homelab`
> namespace — including the Nextcloud **database**. The user *files* survived
> (the data PV is `reclaimPolicy: Retain`), but user accounts, shares,
> calendars/contacts, comments, versions and app config did not, because they
> lived only in Postgres. The trigger was cheap to fix with Git; the *data loss*
> is what hurt. This page records what to back up so a repeat is a boring
> restore instead of a rebuild.

## What matters (and what each backup recovers)

| Layer | Back up | Recovers | Priority |
|------|---------|----------|----------|
| Git repo | `github.com/rykhalskyi/homelab` | every workload / infra manifest | already off-cluster |
| **Secrets** | `infra/k8s/apps/secrets/` **and** `~/.config/sops/age/keys.txt` | every Secret value | critical — key **and** files together |
| **Postgres** | `pg_dump -Fc` of `nextcloud` + `pullini` | users, shares, calendars/contacts, comments, versions metadata, app config, external-storage config | critical |
| **Nextcloud files** | `/home/jaro/ncdata` | user files | critical |
| etcd | k3s snapshots (`/var/lib/rancher/k3s/server/db/snapshots/`) | API objects: Secrets, ConfigMaps, RBAC, Kustomizations (**not** PVC contents) | useful secondary |
| Cloudflare | `~/.cloudflared/<UUID>.json` | tunnel identity | small, easy |
| Other PVCs | `/var/lib/rancher/k3s/storage/` | postgresql-data, nextcloud-html, pullini-data, pgadmin-data, eurooffice-data | low (mostly reproducible; postgres covered by the dump) |

The single highest-value item is the **Postgres dump** — it is the difference
between a full restore (accounts, shares, calendars) and today's outcome
(recreate users + `files:scan`).

## How to back up

### 1. Databases (do this on a schedule)

```bash
PGPW=$(kubectl -n homelab get secret nextcloud-db -o jsonpath='{.data.postgres-password}' | base64 -d)
run_dump() {
  kubectl -n homelab exec postgresql-0 -c postgresql -- env PGPASSWORD="$PGPW" \
    pg_dump -Fc -U postgres -d "$1" > "$2"
}
run_dump nextcloud "nextcloud-$(date +%F).dump"
run_dump pullini   "pullini-$(date +%F).dump"
# then copy both files off-cluster (NAS / object storage / laptop)
```

### 2. Nextcloud data files

```bash
# example: rsync the data dir to the NAS or another host
rsync -a --delete /home/jaro/ncdata/ <backup-host>:/backup/ncdata/
# or, content-addressed/snapshotted:
#   restic -r <repo> backup /home/jaro/ncdata
```

### 3. Encrypted secrets + age key

```bash
# the age key + the encrypted files are useless apart — back them up together
tar czf homelab-secrets-$(date +%F).tgz \
  ~/.config/sops/age/keys.txt \
  -C ~/Source/homelab infra/k8s/apps/secrets
# store in a password manager / offline medium
```

### 4. k3s etcd snapshots

```bash
sudo k3s etcd-snapshot list          # what exists, and retention
sudo k3s etcd-snapshot save          # take one now
# files live under /var/lib/rancher/k3s/server/db/snapshots/
```

### 5. Cloudflare tunnel credential

Copy `~/.cloudflared/<UUID>.json` (and `cert.pem`) to your password manager.

## Restore sketch

1. Fix/revert the offending commit; let Flux rebuild the manifests.
2. Restore Secrets: `bash infra/k8s/apps/secrets/apply.sh` (or `sops -d … | kubectl apply -f -`).
3. Recreate the DB and load the dump:
   ```bash
   PGPW=$(kubectl -n homelab get secret nextcloud-db -o jsonpath='{.data.postgres-password}' | base64 -d)
   kubectl -n homelab exec postgresql-0 -c postgresql -- env PGPASSWORD="$PGPW" \
     psql -U postgres -d postgres -c "DROP DATABASE IF EXISTS nextcloud WITH (FORCE);" \
     -c "CREATE DATABASE nextcloud OWNER nextcloud;"
   kubectl -n homelab exec -i postgresql-0 -c postgresql -- env PGPASSWORD="$PGPW" \
     pg_restore -U postgres -d nextcloud --no-owner < nextcloud-YYYY-MM-DD.dump
   ```
4. Restore `/home/jaro/ncdata` if needed, then
   `occ files:scan --all`.
5. Provision pullini: `bash infra/k8s/apps/pullini/provision-db.sh`.

With a current dump this restores accounts/shares/calendars too — i.e. the
*exact* prior state, in tens of minutes.

## Status / TODO

- **Not automated yet.** Planned:
  - a `pg_dump` CronJob writing `nextcloud` + `pullini` dumps to the NAS,
  - a `restic`/`rsync` job for `/home/jaro/ncdata` + `infra/k8s/apps/secrets/`
    (+ the age key kept separately),
  - verify k3s etcd snapshot retention, and
  - **test one full restore** (an untested backup is not a backup).

## Prevention (why this is a net, not the only guard)

- `infra/k8s/clusters/node-one/kustomization.yaml` now lists `flux-system`
  explicitly (the missing entry is what let Flux prune itself).
- `.github/workflows/kustomize-prune-guard.yml` fails a PR that removes a
  `Namespace`/`CustomResourceDefinition`/`PersistentVolumeClaim` or anything in
  `flux-system` from the build.
- Backups cover everything those two miss.
