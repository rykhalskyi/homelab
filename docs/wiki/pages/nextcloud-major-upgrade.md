---
tags: [nextcloud, k3s, upgrade, helm, flux, gitops, bitnami, postgresql]
date: 2026-09-29
source_count: 0
---

# Nextcloud major upgrade on k3s (31 → 32 → 33)

How the custom Nextcloud image in `infra/images/nextcloud` is moved up one major
version at a time. Done for **31.0.14 → 32.0.15 → 33.0.9** to satisfy the
Euro-Office app (see [[Euro-Office on k3s]]), which needs Nextcloud 33–35.

## Key constraint

The official image entrypoint **refuses a jump larger than one major**:

```
Can't start Nextcloud because upgrading from X to Y is not supported.
It is only possible to upgrade one major version at a time.
```

So going from 31 to 33 is two upgrades, each its own image build.

## How the upgrade actually happens

The entrypoint (in the running image) does it on boot — no manual `rsync` or
`occ upgrade`:

1. It compares `/usr/src/nextcloud/version.php` (image) with
   `/var/www/html/version.php` (the `nextcloud-html` PVC).
2. If the image is newer, it rsyncs the new core over `/var/www/html` while
   excluding `config/`, `data/`, `custom_apps/`, `themes/`, `version.php`
   (`/upgrade.exclude`).
3. It runs `occ upgrade`, then the `before-starting` hook re-enables
   `byebyemoneylist`.

Everything happens inside the existing Pod on rollout; the PVC keeps
`config.php`, data and apps.

## Procedure (per major)

1. **Back up** the database (rollback artifact):
   ```bash
   PGPASS=$(kubectl -n homelab get secret nextcloud-db -o jsonpath='{.data.password}' | base64 -d)
   kubectl -n homelab exec postgresql-0 -- env PGPASSWORD="$PGPASS" pg_dump -Fc -U nextcloud -d nextcloud \
     > nextcloud-preupgrade.dump
   ```
2. **Bump the base image** in `infra/images/nextcloud/versions.env`
   (e.g. `NEXTCLOUD_VERSION=32-apache`), commit and push. For the duration of an
   upgrade, pin `infra/clusters/k8s/apps/nextcloud/helmrelease.yaml`'s chart version
   (`version: "9.3.0"`) so only the image changes.
3. **CI builds** `k3s/nextcloud 2/3 Build Nextcloud image` →
   `ghcr.io/rykhalskyi/homelab-nextcloud:sha-<commit>`.
4. **Merge the pin PR** (`k3s/nextcloud 3/3 Pin Nextcloud image`) — this is what
   makes Flux roll the Pod.
5. **Flux reconciles** `apps`; the new Pod runs the entrypoint upgrade.

Force a reconcile if needed:

```bash
kubectl -n flux-system annotate gitrepository flux-system "reconcile.fluxcd.io/requestedAt=$(date +%s)" --overwrite
kubectl -n flux-system annotate kustomization apps "reconcile.fluxcd.io/requestedAt=$(date +%s)" --overwrite
kubectl -n homelab rollout status deploy/nextcloud --timeout=300s
```

## Verify

```bash
kubectl -n homelab exec deploy/nextcloud -c nextcloud -- php /var/www/html/occ status
kubectl -n homelab exec deploy/nextcloud -c nextcloud -- php /var/www/html/occ app:list | grep byebyemoneylist
kubectl -n homelab logs deploy/nextcloud -c nextcloud | grep -iE "Upgrading nextcloud|have been disabled"
```

Look for `Upgrading nextcloud from <old> ...`, `versionstring` at the new major,
`byebyemoneylist` still enabled, and no apps silently disabled.

## Rollback

Nextcloud does not support code/schema downgrade, so the DB dump is the real
rollback: restore it into `postgresql-0` and re-pin the previous image digest.
The database is the standalone [[PostgreSQL + pgAdmin on k3s (decoupled from
Nextcloud)]] one — dumping it is independent of the app.

## Notes

- `NEXTCLOUD_VERSION` must only ever go forward; a downgrade is impossible.
- The `nextcloud-config` Secret only seeds `config.php` on first boot, so DB
  settings (`dbhost`, `overwrite.cli.url`, ...) live in the PVC and survive.
- Core apps upgrade with the image; the only third-party app was
  `byebyemoneylist` (supports 31–35).
