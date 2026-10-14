---
tags: [forgejo, git, gitea, talos, kubernetes, flux, cnpg, cloudnativepg, minio, restic, backup, sops, lan]
date: 2026-10-14
source_count: 0
---

# Forgejo on Talos (self-hosted git forge, LAN-only)

A self-hosted **Forgejo** (community fork of Gitea) on the `talos` cluster,
moved off the old phase-1 Compose stack. It is **LAN-only** for now, served at
`http://git.homelab.local` through Traefik; a public `git.otakeessen.com` (behind
the existing `*.otakeessen.com` tunnel + **Cloudflare Access**) is a later step.

> **Status: implemented on branch `talos/forgejo` (pending merge + verification).**
> Namespace `forgejo`; CNPG `Cluster forgejo`; served at `git.homelab.local`.
> git-over-SSH is **not** exposed yet (HTTPS only).

## Pieces

| File | Role |
|------|------|
| `infra/clusters/talos/apps/forgejo/namespace.yaml` | `Namespace: forgejo` (self-contained, like `pullini`) |
| `infra/clusters/talos/apps/forgejo/pvc.yaml` | `forgejo-data` (20Gi, `local-path`) -> `/data` (repos + LFS + app.ini) |
| `infra/clusters/talos/apps/forgejo/db-cluster.yaml` | CNPG `Cluster forgejo` (PG 18.4, 1 instance, MinIO backups) |
| `infra/clusters/talos/apps/forgejo/scheduled-backup.yaml` | daily `ScheduledBackup forgejo-daily` (03:00) |
| `infra/clusters/talos/apps/forgejo/deployment.yaml` | Forgejo `16` (digest-pinned), `FORGEJO__*` env config, `/data` mount |
| `infra/clusters/talos/apps/forgejo/service.yaml` | `forgejo:3000` for Traefik |
| `infra/clusters/talos/apps/forgejo/ingress-lan.yaml` | `git.homelab.local` -> service (plain HTTP) |
| `infra/clusters/talos/apps/forgejo/restic-backup.yaml` | daily `forgejo-restic` -> `s3://restic-backups/forgejo` |
| `infra/clusters/talos/apps/secrets/forgejo-*.sops.yaml` | **local only**, out-of-band Secrets |

Config is passed entirely through `FORGEJO__<section>__<KEY>` environment
variables (the same scheme as the Compose stack); Forgejo writes `app.ini` on
first start and generates its own `SECRET_KEY`, which persists on `/data`.
`INSTALL_LOCK=true` skips the web installer, and
`DISABLE_REGISTRATION=true` means accounts are admin-created only.

## Secrets (out of band, never in Git)

| Secret | Keys | Used by |
|--------|------|---------|
| `forgejo-db` | `username`, `password` | CNPG `bootstrap.initdb.secret` + `FORGEJO__database__PASSWD` |
| `cnpg-minio` | `ACCESS_KEY_ID`, `ACCESS_SECRET_KEY` | CNPG `barmanObjectStore` (DB backups) |
| `forgejo-backup` | `RESTIC_PASSWORD`, `ACCESS_KEY_ID`, `ACCESS_SECRET_KEY` | `forgejo-restic` (file backups) |
| `forgejo-admin` | `username`, `password`, `email` | first admin creation (`create-admin.sh`) |

```bash
sops infra/clusters/talos/apps/secrets/forgejo-db.sops.yaml      # and the others
bash infra/clusters/talos/apps/secrets/apply.sh                  # CTX=talos
kubectl --context talos -n forgejo get secret
```

> Like the other CNPG clusters, `cnpg-minio` is **namespace-scoped**: the
> `databases`/`nextcloud` copies are not visible in `forgejo`, so this namespace
> needs its own. The MinIO `cnpg` user's policy must also allow the
> `s3://cnpg-backups/forgejo/*` prefix or DB backups fail with **403** (see
> [[CloudNativePG on Talos (PostgreSQL + MinIO backups)]]).

## Deploy

Merge to `main` and let Flux reconcile (or force it):

```bash
flux reconcile kustomization apps -n flux-system --with-source
kubectl --context talos -n forgejo get cluster,pods,pvc -w
```

Add a client hosts entry, then open it:

```
192.168.2.234 git.homelab.local
```

## First admin user

Forgejo runs with `INSTALL_LOCK=true` and `DISABLE_REGISTRATION=true`, so there
is **no default account and no web sign-up** -- the first admin is created
deliberately from the CLI. The credentials live in the out-of-band
`forgejo-admin` Secret so they are known and reproducible:

```bash
# 1. fill in username / password / email once
sops infra/clusters/talos/apps/secrets/forgejo-admin.sops.yaml

# 2. create the admin (after the Deployment is Ready)
bash infra/clusters/talos/apps/forgejo/create-admin.sh
```

The script decrypts the Secret and runs
`forgejo admin user create --admin --must-change-password=false` inside the pod,
then prints the login URL. Sign in at `http://git.homelab.local/`, enable
**2FA**, and set `FORGEJO__repository__FORCE_PRIVATE=true` if the instance
should default to private repos.

## Backups

Two independent layers, both to the LAN MinIO (192.168.2.112:9000):

- **Database** (users, issues, PRs, releases) -> `s3://cnpg-backups/forgejo`,
  daily base + continuous WAL, 30d retention.
- **Files** (bare repos + LFS under `/data`) -> `s3://restic-backups/forgejo`,
  daily at 02:00, 7d/4w/6m. See [[File-volume backups on Talos (restic → MinIO) — plan]].

## Verify

```bash
kubectl --context talos -n forgejo get cluster forgejo   # Cluster in healthy state
kubectl --context talos -n forgejo get pods,pvc,ingress
curl -s -H 'Host: git.homelab.local' http://192.168.2.234/ | head -1
```

## Future / gotchas

- **Public exposure**: add a `git.otakeessen.com` Ingress (the `*.otakeessen.com`
  tunnel already reaches Traefik) **behind Cloudflare Access**, keep
  registration disabled, and require 2FA. Do not expose it without Access.
- **git-over-SSH**: not exposed (the built-in SSH server is off). Exposing it
  means a node host port / NodePort, since the Cloudflare tunnel only carries
  HTTP.
- **Image upgrades**: `codeberg.org/forgejo/forgejo` is pinned by digest; major
  bumps (`16` -> `17`) need the Forgejo upgrade guide and a manual digest change.
- **PSA**: the namespace does not enforce `restricted`; Forgejo runs as root by
  default (dropping to the `git` user, uid 1000), as in the Compose stack.
