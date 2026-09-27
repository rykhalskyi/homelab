---
tags: [nextcloud, k3s, kubernetes, helm, flux, gitops, migration, byebyemoneylist, aio, ghcr]
date: 2026-09-27
source_count: 0
---

# Nextcloud on k3s (custom image + Helm chart)

How to move Nextcloud from the All-in-One (AIO) Compose stack on `node-one`
onto the k3s cluster, while keeping the `byebyemoneylist` app **inside the
Pod**. This page is the plan and the migration runbook: it explains the target
design and then lists the concrete steps, in the order you should run them.

See [[Byebyemoneylist app integration (Nextcloud AIO)]] for how the app is
delivered today, and [[k3s + GitOps: nginx and cloudflared (phase 2.1)]] for the
cluster that this builds on.

## Goal in one sentence

Nextcloud runs as a normal Kubernetes workload whose image **already contains
`byebyemoneylist`**, is deployed by Flux from Git, and is reached at
`https://cloud.otakeessen.com` through the same Cloudflare tunnel and Traefik as
the rest of the homelab.

## Why not keep AIO in Kubernetes

AIO is a Compose orchestrator, not a Kubernetes app:

- it pins its Nextcloud image to `ghcr.io/nextcloud-releases/aio-nextcloud` and
  has **no supported override**, so the app can never be baked into the image;
- it drives its sibling containers through the host's `docker.sock`;
- the only supported custom-app path is sideloading into `custom_apps`, which is
  the workaround we want to retire.

So on k3s we use the **official `nextcloud` image** (where a custom image is
supported) plus the **official Nextcloud Helm chart**, which Flux manages as a
`HelmRelease` just like Traefik.

## Target picture

```
Cloudflare edge (TLS)
  └── cloud.otakeessen.com → tunnel → Traefik (k3s) → Ingress → nextcloud:8080
                                                                  │
  ┌─────────────────────────────── k3s, ns: homelab ──────────────┴──────────┐
  │                                                                          │
  │  Deployment nextcloud        image: ghcr.io/rykhalskyi/                  │
  │    ├── /var/www/html         PVC nextcloud-html  (code, config, apps)     │
  │    ├── /var/www/html/data    PV  nextcloud-data  → /home/jaro/ncdata      │
  │    ├── initContainer seeds code + config.php on first boot               │
  │    └── before-starting hook copies the app from /opt/byebyemoneylist     │
  │                                                                          │
  │  StatefulSet nextcloud-postgresql   (Bitnami Postgres, chart subchart)   │
  │  Deployment  nextcloud-redis        (Bitnami Redis, chart subchart)      │
  └──────────────────────────────────────────────────────────────────────────┘
```

## What changes, what stays

| Thing | Before (AIO) | After (k3s) |
|-------|--------------|-------------|
| Orchestration | Docker Compose + mastercontainer | k3s + Flux (`HelmRelease`) |
| Nextcloud image | pinned by AIO, no override | our image on GHCR, digest-pinned |
| The app | sideloaded into `custom_apps` by a script | **baked into the image**, overlaid on boot |
| Database | Postgres inside AIO | Bitnami Postgres subchart |
| Cache/locking | Redis inside AIO | Bitnami Redis subchart |
| Data | host `/home/jaro/ncdata` | same path, mounted as a `local` PV |
| Public URL | `cloud.otakeessen.com` | unchanged |
| Deploys | `make nc-app-deploy` on the host | `git push` → Flux reconciles |

## The pieces

| File | Role |
|------|------|
| app repo `Dockerfile` | `FROM nextcloud:<ver>-apache` + app at `/opt/byebyemoneylist` |
| app repo `.github/workflows/image.yml` | build & push the image to GHCR on a `v*` tag |
| `infra/k8s/infrastructure/sources/nextcloud.yaml` | `HelmRepository` for `https://nextcloud.github.io/helm/` |
| `infra/k8s/apps/nextcloud/helmrelease.yaml` | the Nextcloud `HelmRelease` + values |
| `infra/k8s/apps/nextcloud/storage.yaml` | static `local` PV + PVC for `/home/jaro/ncdata`, and `nextcloud-html` PVC |
| `infra/k8s/apps/kustomization.yaml` | adds `- nextcloud` |
| `.github/workflows/update-nextcloud-image-pin.yml` | bumps the image digest in Git (opens a PR) |
| `infra/nextcloud/versions.env` | pinned image tag/digest metadata (no secrets) |

> The manifest files above are the target state for this migration. Until they
> are committed, the steps below describe what to create.

## Part A — Build the Nextcloud image (app repo)

In `~/Source/byebyemoneylist-ns`, add a `Dockerfile` that starts from the
official image and carries the app **outside** `/var/www/html` (so the PVC never
shadows it):

```dockerfile
# byebyemoneylist-ns/Dockerfile
ARG NEXTCLOUD_VERSION=31-apache
FROM nextcloud:${NEXTCLOUD_VERSION}

# Runtime tree only (same set the release tarball ships).
COPY appinfo lib templates l10n js css img \
     composer.json CHANGELOG.md LICENSE README.md /opt/byebyemoneylist/
RUN chown -R www-data:www-data /opt/byebyemoneylist
```

A matching `.github/workflows/image.yml` builds and pushes it on a `v*` tag:

```bash
ghcr.io/rykhalskyi/byebyemoneylist-nextcloud:v<version>
```

Then make the GHCR package **public** (profile → Packages → the image → Package
settings → Change visibility → Public), or the cluster needs an image pull
secret.

> Keep `NEXTCLOUD_VERSION` equal to the **major version AIO is running**. Check
> it with `docker exec -u www-data nextcloud-aio-nextcloud php occ status`. The
> app supports Nextcloud 31–35, and a downgrade is impossible, so the k8s base
> must be the same major or newer.

## Part B — Cluster manifests

### B1. Helm repository

`infra/k8s/infrastructure/sources/nextcloud.yaml`:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: nextcloud
  namespace: flux-system
spec:
  interval: 1h
  url: https://nextcloud.github.io/helm/
```

Add it to `infra/k8s/infrastructure/kustomization.yaml` under `resources:`.

### B2. Storage

`infra/k8s/apps/nextcloud/storage.yaml` defines the data volume (the existing
`/home/jaro/ncdata`) plus a small volume for the rest of `/var/www/html`:

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: nextcloud-data
spec:
  capacity: { storage: 100Gi }
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  local: { path: /home/jaro/ncdata }
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - { key: kubernetes.io/hostname, operator: In, values: [node-one] }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nextcloud-data
  namespace: homelab
spec:
  storageClassName: local-storage
  volumeName: nextcloud-data
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 100Gi } }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nextcloud-html
  namespace: homelab
spec:
  storageClassName: local-path
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 20Gi } }
```

### B3. The HelmRelease

`infra/k8s/apps/nextcloud/helmrelease.yaml` — the important parts:

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: nextcloud
  namespace: homelab
spec:
  interval: 1h
  chart:
    spec:
      chart: nextcloud
      version: ">=5.0.0"            # pin the current stable chart version
      sourceRef: { kind: HelmRepository, name: nextcloud, namespace: flux-system }
  values:
    image:
      registry: ghcr.io
      repository: rykhalskyi/byebyemoneylist-nextcloud
      tag: "v1.0.5@sha256:<digest>"  # tag + digest = immutable pin
    replicaCount: 1
    nextcloud:
      host: cloud.otakeessen.com
      trustedDomains: [cloud.otakeessen.com]
      datadir: /var/www/html/data
      existingSecret:
        enabled: true
        secretName: nextcloud-admin
        usernameKey: nextcloud-username
        passwordKey: nextcloud-password
      extraEnv:
        - { name: TRUSTED_PROXIES, value: "10.42.0.0/16" }
        - { name: APACHE_DISABLE_REWRITE_IP, value: "1" }
        - { name: FORWARDED_FOR_HEADERS, value: "HTTP_X_FORWARDED_FOR HTTP_CF_CONNECTING_IP" }
        - name: SILICONFLOW_API_KEY
          valueFrom:
            secretKeyRef: { name: byebyemoneylist, key: SILICONFLOW_API_KEY }
      # First boot: copy the image's code and our config.php onto the PVC so the
      # entrypoint skips maintenance:install (the DB is already populated).
      extraInitContainers:
        - name: seed-nextcloud
          image: ghcr.io/rykhalskyi/byebyemoneylist-nextcloud:v1.0.5
          command:
            - sh
            - -c
            - |
              set -e
              if [ ! -f /var/www/html/version.php ]; then
                rsync -rlDog --chown www-data:www-data /usr/src/nextcloud/ /var/www/html/
                install -o www-data -g www-data -m 640 /seed/config.php /var/www/html/config/config.php
              fi
          volumeMounts:
            - { name: nextcloud-main, mountPath: /var/www/html, subPath: html }
            - { name: nextcloud-main, mountPath: /var/www/html/config, subPath: config }
            - { name: seed-config, mountPath: /seed, readOnly: true }
      extraVolumes:
        - name: seed-config
          secret: { secretName: nextcloud-config }
      hooks:
        before-starting: |
          #!/bin/sh
          set -e
          SRC=/opt/byebyemoneylist
          APP=/var/www/html/custom_apps/byebyemoneylist
          mkdir -p /var/www/html/custom_apps
          [ -d "$SRC" ] && { rm -rf "$APP"; cp -a "$SRC" "$APP"; }
          [ -n "${SILICONFLOW_API_KEY:-}" ] && {
            printf 'SILICONFLOW_API_KEY=%s\n' "$SILICONFLOW_API_KEY" > "$APP/.env"
            chmod 640 "$APP/.env"
          }
          code="$(sed -n 's:.*<version>\(.*\)</version>.*:\1:p' "$APP/appinfo/info.xml")"
          inst="$(php /var/www/html/occ config:app:get byebyemoneylist installed_version 2>/dev/null || true)"
          if [ "$inst" != "$code" ]; then
            php /var/www/html/occ app:disable byebyemoneylist >/dev/null 2>&1 || true
            php /var/www/html/occ app:enable byebyemoneylist
          fi
    phpClientHttpsFix: { enabled: true, protocol: https }
    persistence:
      enabled: true
      existingClaim: nextcloud-html
      nextcloudData:
        enabled: true
        existingClaim: nextcloud-data
    internalDatabase: { enabled: false }
    externalDatabase:
      enabled: true                 # drives user/password env + Secret ref
      existingSecret: { enabled: true, secretName: nextcloud-db, usernameKey: username, passwordKey: password }
    postgresql:
      enabled: true                 # Bitnami subchart
      global:
        postgresql:
          auth:
            database: nextcloud
            username: nextcloud
            existingSecret: nextcloud-db
            secretKeys: { adminPasswordKey: postgres-password, userPasswordKey: password }
      primary:
        persistence: { enabled: true, storageClass: local-path, size: 8Gi }
    redis:
      enabled: true                 # Bitnami subchart
      auth:
        existingSecret: nextcloud-redis
        existingSecretPasswordKey: redis-password
    ingress: { enabled: true, className: traefik }
    cronjob: { enabled: true, type: cronjob }
    resources:
      requests: { cpu: 100m, memory: 256Mi }
      limits: { memory: 1Gi }
```

Notes:

- The `before-starting` hook is the k8s equivalent of `deploy-app.sh`: it copies
  the baked app onto the PVC, writes `.env` from the Secret, and runs
  `occ app:enable` when the code version differs (which applies migrations).
- With `postgresql.enabled: true` the chart derives the DB host from the
  subchart, but still reads the **user and password** from
  `externalDatabase.existingSecret`, hence the shared `nextcloud-db` Secret.
- `externalDatabase.type` is ignored in this branch, but keep it consistent
  (`postgresql`) if you ever switch to an external DB.

### B4. Wire it into Flux

Add `- nextcloud` to `infra/k8s/apps/kustomization.yaml`. Commit and push; Flux
applies the manifests.

## Part C — Secrets (out of band, never in Git)

Replace the placeholders with real values and keep them somewhere safe:

```bash
DBPASS="$(openssl rand -base64 24)"
ADMPASS="$(openssl rand -base64 18)"     # Nextcloud admin password
REDISPASS="$(openssl rand -base64 24)"

kubectl -n homelab create secret generic nextcloud-db \
  --from-literal=username=nextcloud \
  --from-literal=password="$DBPASS" \
  --from-literal=postgres-password="$DBPASS"

kubectl -n homelab create secret generic nextcloud-admin \
  --from-literal=nextcloud-username=admin \
  --from-literal=nextcloud-password="$ADMPASS"

kubectl -n homelab create secret generic nextcloud-redis \
  --from-literal=redis-password="$REDISPASS"

kubectl -n homelab create secret generic byebyemoneylist \
  --from-literal=SILICONFLOW_API_KEY=sk-...
```

`nextcloud-config` (the seeded `config.php`) is created in the migration step
below, because it is adapted from the AIO config.

## Part D — Migration runbook

This is an **in-place** migration: it reuses `/home/jaro/ncdata`, so only one
Nextcloud may touch that directory at a time. Expect a short maintenance window
(minutes) between stopping AIO and verifying the new Pod.

### D0. Before you start

- The image is published and the GHCR package is public.
- `NEXTCLOUD_VERSION` matches the AIO Nextcloud major.
- Secrets and storage from Parts B/C are applied, but the Nextcloud
  `HelmRelease` is **not** running yet (or `replicaCount: 0`).
- Note the AIO paths: data `/home/jaro/ncdata`, containers
  `nextcloud-aio-nextcloud`, `nextcloud-aio-database`,
  `nextcloud-aio-mastercontainer`.

### D1. Stop writes and dump the AIO database

```bash
# Freeze AIO so the dump is consistent.
docker exec -u www-data nextcloud-aio-nextcloud php occ maintenance:mode --on

docker exec -u postgres nextcloud-aio-database pg_dump -d nextcloud -f /tmp/nextcloud.sql
docker cp nextcloud-aio-database:/tmp/nextcloud.sql ./nextcloud.sql
ls -lh nextcloud.sql
```

### D2. Adapt the AIO `config.php` for Kubernetes

```bash
docker exec nextcloud-aio-nextcloud cat /var/www/html/config/config.php > aio-config.php
```

Edit `aio-config.php` and change **only** these keys:

| Key | New value |
|-----|-----------|
| `datadirectory` | `/var/www/html/data` |
| `dbhost` | `nextcloud-postgresql:5432` |
| `dbpassword` | the `$DBPASS` you created above |
| `dbname` / `dbuser` | `nextcloud` (already) |

Leave `instanceid`, `secret`, and `passwordsalt` **unchanged** — copying them
keeps existing desktop and mobile logins working. Then store it as a Secret and
delete the local copy:

```bash
kubectl -n homelab create secret generic nextcloud-config \
  --from-file=config.php=aio-config.php
rm -f aio-config.php
```

### D3. Start only the database and restore the dump

Temporarily keep Nextcloud at zero replicas so only Postgres and Redis come up:

```bash
kubectl -n homelab get pods -w      # wait for nextcloud-postgresql-0 to be Ready (Ctrl-C)
```

Reset the schema and import the AIO dump:

```bash
kubectl -n homelab exec -i nextcloud-postgresql-0 -- bash -c \
  'PGPASSWORD=$POSTGRES_PASSWORD psql -v ON_ERROR_STOP=1 -U nextcloud -d nextcloud \
     -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"'

kubectl -n homelab exec -i nextcloud-postgresql-0 -- bash -c \
  'PGPASSWORD=$POSTGRES_PASSWORD psql -v ON_ERROR_STOP=1 -U nextcloud -d nextcloud' \
  < nextcloud.sql
```

### D4. Stop AIO and release the data directory

```bash
docker stop nextcloud-aio-nextcloud nextcloud-aio-mastercontainer
```

Stopping the mastercontainer prevents AIO from restarting the Nextcloud
container. The database container is no longer needed; leave it stopped or
running, it does not touch `/home/jaro/ncdata`.

### D5. Start the cluster Nextcloud

Set `replicaCount: 1` in the `HelmRelease` (or remove the temporary override),
commit/push, and let Flux apply it — or force it:

```bash
flux reconcile kustomization apps -n flux-system --with-source
kubectl -n homelab get pods -w
```

On first boot the `seed-nextcloud` init container copies the image's code and
`config.php` onto the PVC. Because `/var/www/html/version.php` now exists and
the restored database is already at the image's version, the entrypoint **skips
`maintenance:install`** and starts directly against the existing data.

### D6. Verify and repair

```bash
kubectl -n homelab exec -u www-data deploy/nextcloud -- \
  php /var/www/html/occ status
kubectl -n homelab exec -u www-data deploy/nextcloud -- \
  php /var/www/html/occ app:list | grep byebyemoneylist
kubectl -n homelab exec -u www-data deploy/nextcloud -- \
  php /var/www/html/occ maintenance:repair
```

Then check the instance locally before touching DNS:

```bash
kubectl -n homelab port-forward svc/nextcloud 8080:8080
# in another terminal:
curl -sI http://localhost:8080/status.php
```

## Part E — Cutover

The in-cluster `cloudflared` already routes the wildcard `*.otakeessen.com` to
Traefik, and the chart created the Ingress for `cloud.otakeessen.com`. The only
thing left is to stop the **host** tunnel so traffic lands in the cluster:

```bash
sudo systemctl disable --now cloudflared
```

Now load `https://cloud.otakeessen.com` and log in. If it works, retire AIO:

```bash
cd ~/Source/homelab
git rm infra/nextcloud/docker-compose.yml infra/nextcloud/deploy-app.sh
git commit -m "Retire the Nextcloud AIO Compose stack"
git push
```

Keep the AIO Docker volumes and `/home/jaro/ncdata` for a while — they are your
rollback.

## Rollback

Both tunnels can run at the same time, and the data directory is untouched by
the migration, so rolling back is cheap:

```bash
# Public traffic back to AIO:
sudo systemctl enable --now cloudflared
docker start nextcloud-aio-mastercontainer nextcloud-aio-nextcloud
docker exec -u www-data nextcloud-aio-nextcloud php occ maintenance:mode --off

# Stop Flux from fighting you:
flux suspend helmrelease nextcloud -n homelab
```

The AIO database still holds the pre-migration data; the dump in `nextcloud.sql`
is a second copy.

## Troubleshooting

| Symptom | Likely cause and fix |
|---------|----------------------|
| Pod stuck in `Init:0/1` / seed errors | `nextcloud-config` Secret missing, or the `nextcloud-html` PVC not bound. Check `kubectl -n homelab describe pod`. |
| `ImagePullBackOff` | The GHCR package is private. Make it public or add an image pull secret. |
| Login page loads, "internal server error" | `config.php` still points at the AIO database. Re-check `dbhost`/`dbpassword` and recreate `nextcloud-config`, then recreate the Pod. |
| `maintenance:install` runs and fails | `/var/www/html/version.php` was not seeded — the init container did not run or the PVC already held a partial tree. Delete the PVC contents and retry. |
| App not listed | The `before-starting` hook found an equal `installed_version` but the code is missing; check the hook logs and `/var/www/html/custom_apps`. |
| 502 from Cloudflare | The host `cloudflared` still runs and points at the stopped AIO port. Disable it (Part E). |
| Stray `appdata_*` directory | Harmless leftover if you ever did a fresh install; the restored DB references the old one. |
| Nextcloud warns `config.php differs from the image` | Cosmetic: our `config.php` intentionally differs from the image stub. |

## Notes and limits

- The app supports Nextcloud 31–35; the base image major must be ≥ the AIO major.
- `session` state lives in Redis; if the Redis PVC is lost, users simply log in
  again.
- The static `local` PV is node-bound (`node-one`). Moving to the future Talos
  cluster means recreating it with the new node's affinity.
- The `nextcloud-config` Secret is only used to seed `config.php` on first boot;
  the init guard (`[ ! -f version.php ]`) means later boots never overwrite it.
- Pinning `image.tag` as `v<version>@sha256:<digest>` gives the same immutable
  deploy as the nginx image; `update-nextcloud-image-pin.yml` refreshes it.

## Go-live checklist

- [ ] App repo image builds and the GHCR package is public
- [ ] `NEXTCLOUD_VERSION` matches the AIO major
- [ ] Secrets created (`nextcloud-db`, `nextcloud-admin`, `nextcloud-redis`, `byebyemoneylist`)
- [ ] Storage PV/PVC bound (`nextcloud-data`, `nextcloud-html`)
- [ ] HelmRepository + HelmRelease applied; Postgres and Redis Ready
- [ ] AIO database dumped and restored into `nextcloud-postgresql`
- [ ] `nextcloud-config` Secret created from the adapted AIO `config.php`
- [ ] AIO Nextcloud/mastercontainer stopped
- [ ] Nextcloud Pod Ready; `occ status` and `occ app:list` good
- [ ] `https://cloud.otakeessen.com` loads through the in-cluster tunnel
- [ ] Host `cloudflared` disabled
- [ ] AIO Compose files removed; volumes and `/home/jaro/ncdata` kept for rollback
- [ ] Wiki rebuilt (`make wiki`) and index/log updated
