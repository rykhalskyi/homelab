---
tags: [pullini, talos, flux, gitops, ghcr, cnpg, postgresql, django, deploy, wiki]
date: 2026-10-11
source_count: 0
---

# Pullini on Talos (CloudNativePG + Flux)

**Pullini** is a read-only, Git-backed wiki browser (Django + HTMX, SQLite *or*
PostgreSQL). It runs on the `talos` cluster as a `Deployment` reconciled by
Flux, stores its data in a dedicated **CloudNativePG** `Cluster`, and is
published at **`https://wiki.otakeessen.com`** through the `*.otakeessen.com`
Cloudflare tunnel.

> Supersedes [[Pullini on k3s (postgresql + Flux)]]. The app was moved off the
> k3s (`node-one`) cluster onto `talos`; the k3s manifests under
> `infra/clusters/k8s/apps/pullini/` were removed. k3s's standalone `postgresql`
> is replaced by a per-app CloudNativePG `Cluster` in the `pullini` namespace.

The app's source lives in the separate `rykhalskyi/pullini` repo. **This homelab
repo is the source of truth** — the manifests here, under
`infra/clusters/talos/apps/pullini/`, are what the cluster runs.

## Picture

```
GitHub rykhalskyi/pullini ──push main──► CI builds
                                          ghcr.io/rykhalskyi/pullini:sha-<sha>
                                                    │
GitHub rykhalskyi/homelab  ◄── pin PR ──────────────┘
        │
        │ Flux (talos `apps` Kustomization)
        ▼
  pullini Deployment (ns pullini)          https://wiki.otakeessen.com
   ├─ web (gunicorn, :8000)   ◄─ Ingress ─ Traefik ─ Cloudflare tunnel
   └─ scheduler (sync_projects loop)        (wildcard *.otakeessen.com)
        └─ /data (2Gi PVC) ──► pullini-rw.pullini.svc:5432/pullini (CNPG)
                                        └─ daily ScheduledBackup ─► MinIO
```

## The pieces

| File | Role |
|------|------|
| `infra/clusters/talos/apps/pullini/namespace.yaml` | `Namespace/pullini` |
| `infra/clusters/talos/apps/pullini/deployment.yaml` | web + scheduler sidecar; pinned image; `wait-for-db` initContainer; PVC mount |
| `infra/clusters/talos/apps/pullini/configmap.yaml` | non-secret Django config (host, CSRF, HSTS, `DATA_DIR`) |
| `infra/clusters/talos/apps/pullini/service.yaml` | ClusterIP `pullini:80` → `http` |
| `infra/clusters/talos/apps/pullini/ingress.yaml` | host `wiki.otakeessen.com` → Traefik |
| `infra/clusters/talos/apps/pullini/middleware.yaml` | forces `X-Forwarded-Proto: https` (TLS ends at Cloudflare) |
| `infra/clusters/talos/apps/pullini/pvc.yaml` | `pullini-data` 2Gi `local-path` (Git clones; disposable) |
| `infra/clusters/talos/apps/pullini/db-cluster.yaml` | CNPG `Cluster pullini` (PG 18.4, 1 instance, MinIO backups) |
| `infra/clusters/talos/apps/pullini/scheduled-backup.yaml` | `ScheduledBackup pullini-daily` (03:00, 30d retention) |
| `infra/clusters/talos/apps/pullini/secret.example.yaml` | template only; the real Secret is out of band (SOPS) |
| `.github/workflows/update-pullini-image-pin.yml` | pins the image digest in a PR |

## Image build

The image is built **on demand**, not on every push. In the `pullini` repo run
**Actions → Build image → Run workflow** (optionally on a branch/tag and with an
extra tag). It pushes `ghcr.io/rykhalskyi/pullini:sha-<commit>` (plus `latest`)
and stamps the commit in via `PULLINI_GIT_SHA`. The GHCR package must be
**public**, or the Pod needs an image pull secret.

`update-pullini-image-pin.yml` then resolves the digest and opens a
`bot/pullini-image-<short>` PR rewriting both image references in
`deployment.yaml` to `sha-<commit>@sha256:<digest>`. Merge it and Flux rolls the
new Pod. If the pullini repo has a `HOMELAB_DISPATCH_TOKEN` Actions secret, the
build dispatches a `pullini-image` event immediately; otherwise trigger the pin
yourself:

```bash
gh workflow run update-pullini-image-pin.yml -f sha=<pullini-commit>
```

### Which build is running?

```bash
kubectl --context talos -n pullini get deploy pullini -o jsonpath='{...containers[0].image}'
docker buildx imagetools inspect ghcr.io/rykhalskyi/pullini:sha-<commit>
```

## Secrets (out of band, SOPS, never in Git)

Talos secrets are local, SOPS/age-encrypted files under
`infra/clusters/talos/apps/secrets/` (gitignored), applied with `apply.sh`
(`CTX=talos`, the default). Two files, one Secret each:

| SOPS file | Secret | Keys |
|-----------|--------|------|
| `pullini-secrets.sops.yaml` | `pullini-secrets` (ns `pullini`) | `username`, `password`, `DATABASE_URL`, `DJANGO_SECRET_KEY`, `DJANGO_SUPERUSER_*` |
| `pullini-minio.sops.yaml` | `cnpg-minio` (ns `pullini`) | `ACCESS_KEY_ID`, `ACCESS_SECRET_KEY` (backups) |

`username` / `password` are the CNPG bootstrap credentials
(`bootstrap.initdb.secret`); `password` **must** match the password embedded in
`DATABASE_URL`:

```
postgres://pullini:<password>@pullini-rw.pullini.svc.cluster.local:5432/pullini
```

`cnpg-minio` is **namespace-scoped**: even though the MinIO credentials are the
same as the shared `databases` / `nextcloud` copies, the `pullini` namespace
needs its own Secret.

```bash
sops infra/clusters/talos/apps/secrets/pullini-secrets.sops.yaml   # create/edit
sops infra/clusters/talos/apps/secrets/pullini-minio.sops.yaml
bash infra/clusters/talos/apps/secrets/apply.sh                    # decrypt + apply (CTX=talos)
kubectl --context talos -n pullini get secret pullini-secrets
```

## Database provisioning (CloudNativePG)

The `db-cluster.yaml` `Cluster/pullini` is created empty with the `pullini`
database owned by `pullini` (`bootstrap.initdb`), using the `pullini-secrets`
credentials. There is **no** `provision-db.sh` and no separate DB secret: the
one `pullini-secrets` Secret is the single source of truth. The CNPG operator
creates the `pullini-rw` Service.

Backups: continuous WAL archiving + a daily base backup to
`s3://cnpg-backups/pullini` on the LAN MinIO (`192.168.2.112:9000`). The MinIO
`cnpg` user's policy must include the `pullini/*` prefix:

```jsonc
"Resource": ["arn:aws:s3:::cnpg-backups/talos/*",
             "arn:aws:s3:::cnpg-backups/nextcloud/*",
             "arn:aws:s3:::cnpg-backups/pullini/*"]
```

(Keep `s3:ListBucket` unconditional on the whole bucket.) See
[[CloudNativePG on Talos (PostgreSQL + MinIO backups)]] for the MinIO/policy
mechanics.

## Admin bootstrap

Pullini's `docker/entrypoint.sh` runs, after `migrate` and `collectstatic`, a
`create_superuser` shell snippet when `DJANGO_SUPERUSER_PASSWORD` is set. So the
first web Pod creates `admin` from `pullini-secrets`; an existing user is left
untouched (safe on every restart). The scheduler sidecar sets
`PULLINI_SKIP_BOOTSTRAP=true`, so it never runs the bootstrap.

To rotate the admin password, update the Secret and
`kubectl --context talos -n pullini exec deploy/pullini -c web -- python manage.py changepassword admin`,
or delete the user and restart the Pod.

## Deploy

The `pullini-secrets` Secret must exist **before** Flux rolls the Deployment out
(otherwise Pods fail with `CreateContainerConfigError`); the `wait-for-db`
initContainer then blocks until `pullini-rw` accepts connections before the
entrypoint runs `migrate`. Order:

1. Create the two SOPS Secrets and apply them (also creates the namespace).
2. Commit/push the manifests; Flux reconciles.

```bash
flux reconcile kustomization apps -n flux-system --context talos --with-source
kubectl --context talos -n pullini rollout status deploy/pullini
kubectl --context talos -n pullini logs deploy/pullini -c web | grep -i superuser
```

> One-time DNS: the wildcard `*.otakeessen.com` already routes to the talos
> Traefik (see `apps/cloudflared/`), so `wiki.otakeessen.com` needs no extra
> tunnel/DNS record.

## Verify

```bash
kubectl --context talos -n pullini get cluster,pods,ingress
kubectl --context talos -n pullini get backup,scheduledbackup
curl -I https://wiki.otakeessen.com/healthz
```

Then log in at `https://wiki.otakeessen.com/admin/`, add a project (git URL,
branch, docs folder, interval), and confirm the scheduler clones it under the
PVC and generates pages.

## Updating pullini

1. In `pullini`, run **Actions → Build image → Run workflow** → builds
   `sha-<commit>`.
2. Merge the auto-opened pin PR (or run the pin workflow manually with the SHA).
3. Flux reconciles; the entrypoint runs migrations on the new Pod.

## Troubleshooting

- **Pod never becomes Ready; logs show `DisallowedHost: Invalid HTTP_HOST
  header: '10.244.x.y:8000'`.** Kubelet probes connect to the Pod IP and send it
  as the `Host` header, which Django rejects because `DJANGO_ALLOWED_HOSTS` only
  lists `wiki.otakeessen.com`. The probes in `deployment.yaml` therefore set
  `httpHeaders: [{name: Host, value: wiki.otakeessen.com}]`. (A `301` from
  `SECURE_SSL_REDIRECT` still counts as probe success.)
- **`CreateContainerConfigError`.** `pullini-secrets` is missing in namespace
  `pullini` — apply the SOPS Secret before the Deployment rolls out.
- **`wait-for-db` never completes.** The CNPG `pullini` Cluster is not ready or
  the `pullini-rw` Service is missing — check
  `kubectl --context talos -n pullini get cluster pullini`.
- **Backups fail with `403 ... HeadBucket`.** The MinIO `cnpg` policy does not
  allow the `pullini/*` prefix (or the namespaced `pullini-minio` Secret is
  missing).

## Rollback

```bash
flux suspend kustomization apps -n flux-system --context talos
kubectl --context talos -n pullini scale deploy/pullini --replicas=0
```

Re-pin the previous digest (revert the pin PR) and `flux resume`. The database
and PVC are untouched, so this is lossless.
