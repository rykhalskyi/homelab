---
tags: [talos, kubernetes, postgresql, postgres, cnpg, cloudnativepg, minio, s3, backup, wal, flux, gitops, sops]
date: 2026-10-10
source_count: 0
---

# CloudNativePG on Talos (PostgreSQL + MinIO backups)

Run a PostgreSQL cluster on the `talos` cluster with the **CloudNativePG (CNPG)**
operator, with continuous WAL archiving and a daily base backup to the LAN
**MinIO** bucket. Everything except the credentials is reconciled by Flux from
`infra/clusters/talos/`; the MinIO keys live in a local SOPS Secret (see
[[Secrets with SOPS + age (local, out-of-band)]]).

> **Status (2026-10-10): created.** Operator + a single-instance `postgres`
> Cluster in namespace `databases`, backups to `s3://cnpg-backups/talos` on
> MinIO at `192.168.2.112:9000`.

## Target picture

```
databases/postgres  (CloudNativePG Cluster, 1 instance, PG 18)
        │  WAL + base backups (barman-cloud)
        ▼
MinIO 192.168.2.112:9000   s3://cnpg-backups/talos/           (LAN, not in cluster)
```

## Why CNPG

- Operator-managed Postgres: rolling updates, self-healing, failover.
- Declarative `Cluster` CR that fits the Flux/GitOps model.
- First-class backup/recovery to S3-compatible object storage (MinIO).
- The planned multi-node Talos cluster can grow the same `Cluster` to 3
  instances (HA) by changing one field (`spec.instances`).

## The pieces

| File | Role |
|------|------|
| `infra/clusters/talos/infrastructure/sources/cloudnative-pg.yaml` | `HelmRepository` → `https://cloudnative-pg.github.io/charts` |
| `infra/clusters/talos/infrastructure/cnpg/namespace.yaml` | `Namespace: cnpg-system` (operator) |
| `infra/clusters/talos/infrastructure/cnpg/databases-namespace.yaml` | `Namespace: databases` (workload) |
| `infra/clusters/talos/infrastructure/cnpg/helmrelease.yaml` | operator `HelmRelease`, chart pinned |
| `infra/clusters/talos/infrastructure/cnpg/kustomization.yaml` | operator layer (`infrastructure`) |
| `infra/clusters/talos/apps.yaml` | Flux Kustomization for workloads (`dependsOn: infrastructure`) |
| `infra/clusters/talos/apps/cnpg/cluster.yaml` | the `Cluster` CR + `barmanObjectStore` |
| `infra/clusters/talos/apps/cnpg/scheduled-backup.yaml` | daily `ScheduledBackup` |
| `infra/clusters/talos/apps/cnpg/kustomization.yaml` | bundles the CNPG workload |
| `infra/clusters/talos/apps/secrets/cnpg-minio.sops.yaml` | **local only**, MinIO keys |

Pinned versions:

- CNPG chart **0.29.1** (operator **1.30.1**; default operand **PostgreSQL 18.4**).
- Operand image `ghcr.io/cloudnative-pg/postgresql:18.4-system-trixie` pinned by
  digest `sha256:42708a75…98e185`.
- The `system` image variant is required because the **in-tree**
  `barmanObjectStore` backend uses the bundled `barman-cloud` binaries.

## Two layers (infrastructure + apps)

- **`infrastructure`** → namespace **`cnpg-system`**: the operator, which owns
  the `postgresql.cnpg.io` CRDs and watches all namespaces. It also creates the
  `databases` namespace.
- **`apps`** → namespace **`databases`**: the `Cluster` and `ScheduledBackup`
  CRs.

Why split: a CR cannot live in the same Flux Kustomization that installs its
CRD. kustomize-controller server-side **dry-runs** the whole set, and a
`ScheduledBackup`/`Cluster` whose CRD doesn't exist yet fails with
`no matches for kind ...`, which aborts the entire apply — so the operator never
installs and nothing converges. Putting the CRs in a separate `apps`
Kustomization that `dependsOn: infrastructure` guarantees the CRDs exist first.

## MinIO setup (out of band, on the NAS)

MinIO no longer publishes `minio/mc` on Docker Hub, so use the static `mc`
binary from GitHub releases (single file, no install):

```bash
mkdir -p /volume1/docker/bin && cd /volume1/docker/bin
curl -fsSL -O https://github.com/minio/mc/releases/download/RELEASE.2025-08-13T08-35-41Z/mc.linux-amd64.RELEASE.2025-08-13T08-35-41Z
mv mc.linux-amd64.RELEASE.2025-08-13T08-35-41Z mc && chmod +x mc

# Synology: $HOME/.mc is unwritable under sudo — point mc's config elsewhere
export MC_CONFIG_DIR=/volume1/docker/mc
./mc alias set local http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"
./mc admin info local
```

Create the bucket + a least-privilege user and a service account (the "API
key") that CNPG uses:

```bash
./mc mb local/cnpg-backups
./mc admin user add local cnpg '<strong-password>'

# /volume1/docker/cnpg-policy.json — read bucket metadata, write under talos/ and nextcloud/
cat > /volume1/docker/cnpg-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": ["arn:aws:s3:::cnpg-backups"] },
    { "Effect": "Allow",
      "Action": ["s3:GetObject","s3:PutObject","s3:DeleteObject",
                 "s3:ListMultipartUploadParts","s3:AbortMultipartUpload"],
      "Resource": ["arn:aws:s3:::cnpg-backups/talos/*",
                   "arn:aws:s3:::cnpg-backups/nextcloud/*"] }
  ]
}
EOF

./mc admin policy create local cnpg-rw /volume1/docker/cnpg-policy.json
./mc admin policy attach local cnpg-rw --user cnpg
./mc admin user svcacct add local cnpg        # newer mc: accesskey create
```

Two MinIO gotchas hit while building this:

- **`s3:ListBucket` must be unconditional.** Prefix-scoping it with an
  `s3:prefix` condition looks tighter, but barman-cloud calls `HeadBucket`
  first (which needs `s3:ListBucket` with **no** prefix) and gets
  **403 Forbidden** — the backup then hangs in `running` while WAL archiving
  fails with `403 ... HeadBucket operation: Forbidden`. Keep object writes
  scoped to `talos/*`, but grant `s3:ListBucket`/`s3:GetBucketLocation` on the
  whole bucket. (`s3:prefix` is also valid *only* for `s3:ListBucket`; attaching
  it to `s3:GetBucketLocation` is rejected outright.)
- MinIO images are **not on Docker Hub** anymore; `docker run minio/mc` fails
  with `pull access denied`. Use the GitHub-release binary above.

## Credentials

The service-account Access Key / Secret Key go into a local, SOPS-encrypted
Secret (`databases/cnpg-minio`, keys `ACCESS_KEY_ID` / `ACCESS_SECRET_KEY`).
It is git-ignored and applied out of band:

```bash
sops infra/clusters/talos/apps/secrets/cnpg-minio.sops.yaml   # edit + encrypt
bash infra/clusters/talos/apps/secrets/apply.sh               # decrypt + apply (CTX=talos)
kubectl --context talos -n databases get secret cnpg-minio
```

The `Cluster` references it via `s3Credentials` — no secrets in Git.

> **Second cluster.** The `nextcloud` Cluster (see [[Nextcloud + Euro-Office on
> Talos (LAN-only)]]) backs up to `s3://cnpg-backups/nextcloud` using the same
> MinIO user. Because Secrets are namespaced it needs its **own**
> `cnpg-minio` Secret in `nextcloud` (`apps/secrets/nextcloud-minio.sops.yaml`),
> and the MinIO policy above must include the `nextcloud/*` prefix.

## Deploy

Commit and let Flux reconcile, or force it:

```bash
flux reconcile kustomization infrastructure -n flux-system --with-source
kubectl -n cnpg-system get pods -w          # cnpg-controller-manager
flux reconcile kustomization apps -n flux-system --with-source
```

Operator pods land in `cnpg-system`; the database pods (`postgres-1`) in
`databases`.

## Verify

```bash
kubectl -n cnpg-system get deploy                         # cnpg-controller-manager 1/1
kubectl -n databases get cluster postgres                 # STATUS: Cluster in healthy state
kubectl -n databases get pods                             # postgres-1 1/1

# on-demand base backup
kubectl cnpg backup databases/postgres --method=barmanObjectStore
kubectl -n databases get backup                           # phase: completed
kubectl -n databases describe backup <name>               # Destination Path / Endpoint URL

# objects in MinIO (on the NAS)
./mc ls -r local/cnpg-backups/talos/                      # base/, wals/
```

Connect from inside the cluster: the RW service is
`postgres-rw.databases.svc.cluster.local:5432`. The app credentials are in the
operator-generated `postgres-app` Secret; `postgres-superuser` exists if the
cluster is created with `enableSuperuserAccess: true`.

## Backups

- **Continuous WAL archiving** starts as soon as the `backup.barmanObjectStore`
  stanza is present; `archive_timeout` defaults to 5 min (RPO ≤ 5 min).
- **Daily base backup** via `ScheduledBackup postgres-daily` at `03:00`
  (six-field cron, seconds first).
- **Retention** `30d` is set on the Cluster (`spec.backup.retentionPolicy`).

> `barmanObjectStore` is **deprecated since CNPG 1.26** in favour of the
> CNPG-I **Barman Cloud Plugin**. It still works and needs no extra components;
> migrating later requires `cert-manager` + the plugin + an `ObjectStore` CRD
> and switching `spec.method: plugin`.

## Restore sketch

Recover into a new Cluster from the same object store:

```yaml
spec:
  bootstrap:
    recovery:
      source: minio
  externalClusters:
    - name: minio
      barmanObjectStore:
        destinationPath: s3://cnpg-backups/talos
        endpointURL: http://192.168.2.112:9000
        s3Credentials:
          accessKeyId:     { name: cnpg-minio, key: ACCESS_KEY_ID }
          secretAccessKey: { name: cnpg-minio, key: ACCESS_SECRET_KEY }
```

Point-in-time recovery adds `recoveryTarget.targetTime`. Always test a restore
— see [[Backups: what to save and how to restore]].

## Gotchas

- **Ordering.** The `Cluster`/`ScheduledBackup` CRs are in the `apps`
  Kustomization, which `dependsOn` `infrastructure`. Do **not** move them back
  into `infrastructure`: the same-Kustomization CR-before-CRD dry-run failure
  blocks the operator from ever installing.
- **Not HA yet.** One instance = no failover. Raising `spec.instances` to 3
  needs the other Talos nodes and (ideally) anti-affinity.
- **`local-path` volumes** are node-local; a `Cluster` instance is pinned to the
  node holding its PVC. Fine for a single node; revisit for multi-node.
- **`system` operand image** carries `barman-cloud`. If you move to the plugin,
  switch to `minimal`/`standard`.
- **Region** is mostly ignored by MinIO; the barman client sends `us-east-1`.

## Rollback

Delete the `cnpg` entries from
`infra/clusters/talos/infrastructure/kustomization.yaml` (operator) and
`infra/clusters/talos/apps/kustomization.yaml` (workload), commit, and let Flux
prune them (drop `apps.yaml` from the root Kustomization too if the whole apps
layer is going away). Remove the `databases` namespace/Secret and the MinIO
objects separately (Flux does not own the out-of-band Secret).
