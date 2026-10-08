---
tags: [nextcloud, k3s, postgresql, pgadmin, database, migration, gitops, flux, bitnami]
date: 2026-09-29
source_count: 0
---

# PostgreSQL + pgAdmin on k3s (decoupled from Nextcloud)

How to run Nextcloud's database as its **own** PostgreSQL workload instead of the
`postgresql` subchart bundled with the Nextcloud Helm chart, and how to inspect
it with a LAN-only pgAdmin. This is the first half of the [[Nextcloud on k3s
(custom image + Helm chart)]] follow-up; the Nextcloud 31→33 upgrade and the
Euro-Office app come **after** this and are not covered here.

> **Status (2026-09-29): executed.** Nextcloud now runs on the standalone
> `postgresql`; the subchart is disabled in the `nextcloud` HelmRelease. The
> pre-migration dump is kept at `/tmp/opencode/nextcloud-nc31.dump` (move it
> somewhere persistent) and the old `data-nextcloud-postgresql-0` PVC was left
> untouched as rollback.

## Why decouple

- The database lifecycle stops being tied to the Nextcloud chart version.
- It is easy to dump/restore and roll back independently of the app.
- One obvious DB endpoint (`postgresql:5432`) instead of the
  subchart + `externalDatabase` tangle.
- No HA gain on a single node — this is about separation and operability.

## Target picture

```
nextcloud (pod, 31.0.14) ──► postgresql.homelab.svc:5432   (Bitnami HelmRelease, own PVC)
                                    ▲
pgadmin.homelab.svc ◄── pgAdmin Deployment ──► http://pgadmin.homelab.local/  (LAN only)
```

The Postgres major stays **17** to match the subchart it replaces, so the
migration is a plain logical dump/restore (no `pg_upgrade`).

## The pieces

| File | Role |
|------|------|
| `infra/clusters/k8s/infrastructure/sources/postgresql-chart.yaml` | `OCIRepository` for the Bitnami `postgresql` chart |
| `infra/clusters/k8s/apps/postgresql/helmrelease.yaml` | standalone Postgres `HelmRelease` (uses `chartRef` → the `OCIRepository`) |
| `infra/clusters/k8s/apps/postgresql/kustomization.yaml` | adds it to the `apps` Kustomization |
| `infra/clusters/k8s/apps/pgadmin/{pvc,deployment,service,ingress}.yaml` | LAN-only pgAdmin |
| `infra/clusters/k8s/apps/nextcloud/helmrelease.yaml` | `redis.architecture: standalone` (slims Redis to 1 pod) |

Pinned versions:

- Postgres chart `postgresql` **16.7.27** (appVersion Postgres **17.6.0**),
  image `bitnamilegacy/postgresql:17.6.0-debian-12-r4`.
- pgAdmin image `dpage/pgadmin4:9.18.0@sha256:c332c5f6…26de`.

Three environment details matter:

- Bitnami moved the community images to `bitnamilegacy`; the chart verifies
  image provenance, so `global.security.allowInsecureImages: true` is set, and
  the `volumePermissions` init image is also pointed at `bitnamilegacy/os-shell`.
- `volumePermissions.enabled: true` chowns the root-owned `local-path` volume
  before Postgres (uid 1001) starts.
- **Bitnami's charts are OCI-only now.** The legacy
  `https://charts.bitnami.com/bitnami` index lists every chart as
  `oci://registry-1.docker.io/bitnamicharts/...`, so a `HelmRepository`
  (generic) fails with `unsupported protocol scheme "oci"`. The chart is
  therefore consumed through an `OCIRepository` and the `HelmRelease` points at
  it with `chartRef` (not `chart.spec`).

## Credentials

The standalone Postgres **reuses the existing `nextcloud-db` Secret** (keys
`username`, `password`, `postgres-password`), so Nextcloud's DB user/password/
database do not change — only `dbhost` does.

pgAdmin login is a separate, out-of-band Secret (never in Git):

```bash
kubectl -n homelab create secret generic pgadmin-auth \
  --from-literal=PGADMIN_DEFAULT_EMAIL=admin@otakeessen.com \
  --from-literal=PGADMIN_DEFAULT_PASSWORD="$(openssl rand -base64 18)"
# read it back:
kubectl -n homelab get secret pgadmin-auth \
  -o jsonpath='{.data.PGADMIN_DEFAULT_PASSWORD}' | base64 -d; echo
```

## Deploy

Commit and push; Flux reconciles the `infrastructure` and `apps` Kustomizations
(each on its own 10m interval, or force them):

```bash
flux reconcile kustomization infrastructure -n flux-system --with-source
flux reconcile kustomization apps -n flux-system --with-source
kubectl -n homelab get pods -w   # postgresql-0, pgadmin
```

## LAN access to pgAdmin

The Ingress host is **`pgadmin.homelab.local`**, deliberately *not* under
`*.otakeessen.com`, so the Cloudflare tunnel (which routes that wildcard only)
never exposes it publicly. Add to each client's `/etc/hosts`:

```
192.168.2.233 pgadmin.homelab.local
```

Then open `http://pgadmin.homelab.local/`. Log in with the `pgadmin-auth` email and
password, and register the server: host `postgresql`, port `5432`, database
`nextcloud`, user `nextcloud` (password from `nextcloud-db`).

> Pi-hole currently is **not** running. When it is started with its current
> Compose file it will try to bind host ports 80/443, which `svclb-traefik`
> already holds on `node-one`. Remap Pi-hole's web ports before starting it, or
> LAN Ingress (including this pgAdmin one) breaks.

## Migration runbook (short maintenance window)

1. Confirm `postgresql-0` and `pgadmin` are `Ready`, and the pgAdmin connection
   to the new (empty) database works.
2. Freeze writes:
   ```bash
   kubectl -n homelab exec deploy/nextcloud -c nextcloud -- \
     php /var/www/html/occ maintenance:mode --on
   ```
3. Dump the old subchart database off-cluster:
   ```bash
   kubectl -n homelab exec nextcloud-postgresql-0 -- bash -c \
     'PGPASSWORD=$POSTGRES_PASSWORD pg_dump -Fc -U nextcloud -d nextcloud' \
     > nextcloud-nc31.dump
   ls -lh nextcloud-nc31.dump
   ```
4. Restore into the new Postgres:
   ```bash
   kubectl -n homelab cp nextcloud-nc31.dump postgresql-0:/tmp/nextcloud.dump
   kubectl -n homelab exec postgresql-0 -- bash -c \
     'PGPASSWORD=$POSTGRES_PASSWORD pg_restore --no-owner --no-acl \
        -U nextcloud -d nextcloud /tmp/nextcloud.dump'
   ```
5. Repoint Nextcloud — set `dbhost` and drop the subchart:
   ```bash
   kubectl -n homelab exec deploy/nextcloud -c nextcloud -- \
     php /var/www/html/occ config:system:set dbhost --value=postgresql
   ```
   In `infra/clusters/k8s/apps/nextcloud/helmrelease.yaml`: `postgresql.enabled: false`
   and add `externalDatabase.host: postgresql` + `externalDatabase.type:
   postgresql`. Commit, push, and reconcile `apps`.
6. Nextcloud restarts against the new DB. Take it out of maintenance mode:
   ```bash
   kubectl -n homelab exec deploy/nextcloud -c nextcloud -- \
     php /var/www/html/occ maintenance:mode --off
   ```
7. Keep the old `data-nextcloud-postgresql-0` PVC **and** `nextcloud-nc31.dump`
   as the rollback until you are confident.

## Verify

```bash
kubectl -n homelab exec deploy/nextcloud -c nextcloud -- php /var/www/html/occ status
kubectl -n homelab exec deploy/nextcloud -c nextcloud -- php /var/www/html/occ app:list | grep byebyemoneylist
kubectl -n homelab get pods -n homelab          # postgresql-0 1/1, redis 1 pod
```

Then log in at `https://cloud.otakeessen.com`, open/upload a file, and check
Calendars/Contacts. In pgAdmin the `nextcloud` database should show the tables.

## Rollback

Revert the two HelmRelease lines (`postgresql.enabled: true`, remove
`externalDatabase.host`) and point Nextcloud back:

```bash
kubectl -n homelab exec deploy/nextcloud -c nextcloud -- \
  php /var/www/html/occ config:system:set dbhost --value=nextcloud-postgresql
```

The old PVC was never touched, so this is a fast, lossless rollback.

## Notes and limits

- Keeping Postgres 17 avoided a major-version migration; moving to 18 later is
  a separate dump/restore.
- Redis now runs standalone (1 pod). Switching architecture leaves the old
  `redis-data-nextcloud-redis-replicas-*` PVCs behind; delete them when happy.
- pgAdmin is single-user (`SERVER_MODE=True`) with its own login, reachable only
  from the LAN.
- This page is the prerequisite for the planned **Nextcloud 31→33** upgrade and
  the **Euro-Office** integration (which need Nextcloud 33).
