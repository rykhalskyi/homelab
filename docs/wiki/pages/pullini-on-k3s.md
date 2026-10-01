---
tags: [pullini, k3s, flux, gitops, ghcr, postgresql, django, deploy, wiki]
date: 2026-10-01
source_count: 0
---

# Pullini on k3s (postgresql + Flux)

**Pullini** is a read-only, Git-backed wiki browser (Django + HTMX, SQLite *or*
PostgreSQL). It runs on `node-one`'s k3s cluster as a `Deployment` reconciled by
Flux, stores its data in the existing standalone **PostgreSQL**, and is published
at **`https://wiki.otakeessen.com`** through the `*.otakeessen.com` Cloudflare
tunnel.

The app's source lives in the separate `rykhalskyi/pullini` repo. Its own `k8s/`
folder is only a reference: **this homelab repo is the source of truth** — the
manifests here, under `infra/k8s/apps/pullini/`, are what the cluster runs.

## Picture

```
GitHub rykhalskyi/pullini ──push main──► CI builds
                                          ghcr.io/rykhalskyi/pullini:sha-<sha>
                                                    │
GitHub rykhalskyi/homelab  ◄── pin PR ──────────────┘
        │
        │ Flux (apps Kustomization)
        ▼
  pullini Deployment (ns homelab)          https://wiki.otakeessen.com
   ├─ web (gunicorn, :8000)   ◄─ Ingress ─ Traefik ─ Cloudflare tunnel
   └─ scheduler (sync_projects loop)        (wildcard *.otakeessen.com)
        └─ /data (5Gi PVC)   ──► postgresql.homelab.svc:5432/pullini
```

## The pieces

| File | Role |
|------|------|
| `infra/k8s/apps/pullini/deployment.yaml` | web + scheduler sidecar; pinned image; PVC mount |
| `infra/k8s/apps/pullini/configmap.yaml` | non-secret Django config (host, CSRF, HSTS, `DATA_DIR`) |
| `infra/k8s/apps/pullini/service.yaml` | ClusterIP `pullini:80` → `http` |
| `infra/k8s/apps/pullini/ingress.yaml` | host `wiki.otakeessen.com` → Traefik |
| `infra/k8s/apps/pullini/middleware.yaml` | forces `X-Forwarded-Proto: https` (TLS ends at Cloudflare) |
| `infra/k8s/apps/pullini/pvc.yaml` | `pullini-data` 5Gi `local-path` (Git clones; disposable) |
| `infra/k8s/apps/pullini/provision-db.sh` | idempotent role/database provisioning |
| `infra/k8s/apps/pullini/secret.example.yaml` | template only; the real Secret is out of band |
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

The first-ever rollout may use `:latest` (as committed); the pin PR makes it
immutable right after.

### Which build is running?

Three ways to tell:

- `kubectl -n homelab get deploy pullini -o jsonpath='{...containers[0].image}'`
  — the pinned `sha-<commit>@sha256:<digest>` is the ground truth.
- `/healthz` while logged in as staff returns `version` (app version, e.g.
  `0.1.0`) and `revision` (the commit baked in at build time); anonymous callers
  get these redacted.
- `docker buildx imagetools inspect ghcr.io/rykhalskyi/pullini:sha-<commit>`
  shows the OCI revision label.

## Secrets (out of band, never in Git)

All application secrets live in one Secret, `pullini-secrets` in namespace
`homelab`:

```bash
kubectl -n homelab create secret generic pullini-secrets \
  --from-literal=DJANGO_SECRET_KEY="$(python3 -c 'import secrets;print(secrets.token_urlsafe(50))')" \
  --from-literal=DATABASE_URL='postgres://pullini:<DB_PASSWORD>@postgresql.homelab.svc.cluster.local:5432/pullini' \
  --from-literal=DJANGO_SUPERUSER_USERNAME='admin' \
  --from-literal=DJANGO_SUPERUSER_EMAIL='you@example.com' \
  --from-literal=DJANGO_SUPERUSER_PASSWORD="$(python3 -c 'import secrets;print(secrets.token_urlsafe(24))')"
```

| Key | Used by |
|-----|---------|
| `DJANGO_SECRET_KEY` | Django (required, ≥32 chars in production) |
| `DATABASE_URL` | app DB, and the source of truth for `provision-db.sh` |
| `DJANGO_SUPERUSER_USERNAME` / `_EMAIL` / `_PASSWORD` | admin bootstrap (below) |

There is **no separate DB secret**: the Postgres password is embedded in
`DATABASE_URL`.

## Database provisioning

Pullini uses a dedicated `pullini` role and `pullini` database on the existing
standalone `postgresql` (see [[PostgreSQL + pgAdmin on k3s (decoupled from
Nextcloud)]]). `provision-db.sh` is idempotent, reads `DATABASE_URL` from
`pullini-secrets`, and talks to `postgresql-0` with the existing superuser
credential (`nextcloud-db` key `postgres-password`):

```bash
bash infra/k8s/apps/pullini/provision-db.sh
```

It creates the role if missing, always resets its password to match
`DATABASE_URL`, and creates the database owned by the role if missing. Because
the password comes from the Secret and the script is in Git, **recovering a
rebuilt/migrated cluster is: recreate the Secret, run this one script.**

## Admin bootstrap

Django can seed the single admin user (HLD V1 principle 3) from the environment.
Pullini's `docker/entrypoint.sh` runs, after `migrate` and `collectstatic`:

```sh
if [ -n "${DJANGO_SUPERUSER_PASSWORD:-}" ]; then
  python manage.py shell -c "..."   # create_superuser if the user is absent
fi
```

So the first web Pod creates `admin` from `pullini-secrets`; an existing user is
left untouched (safe on every restart). The scheduler sidecar sets
`PULLINI_SKIP_BOOTSTRAP=true`, so it never runs the bootstrap.

To rotate the admin password, either update the Secret and
`kubectl -n homelab exec deploy/pullini -c web -- python manage.py changepassword admin`,
or delete the user and restart the Pod.

## Deploy

The Secret must exist **before** the Deployment rolls out (otherwise Pods fail
with `CreateContainerConfigError`), and the database must be provisioned before
the entrypoint can `migrate`. Order:

1. Create `pullini-secrets` (above).
2. Run `provision-db.sh`.
3. Commit/push the manifests; Flux reconciles.

```bash
flux reconcile kustomization apps -n flux-system --with-source
kubectl -n homelab rollout status deploy/pullini
kubectl -n homelab logs deploy/pullini -c web | grep -i superuser   # "created superuser 'admin'"
```

> One-time DNS: the wildcard `*.otakeessen.com` already routes to Traefik, so
> `wiki.otakeessen.com` needs no extra tunnel/DNS record.

## Verify

```bash
kubectl -n homelab get pods -l app=pullini
kubectl -n homelab get ingress pullini -o wide
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

## Migration to another node / cluster

Everything except the database is reproducible from Git + Secrets:

- Manifests: Flux re-applies them on the new cluster.
- `pullini-secrets`: recreate it (out of band).
- DB role/database: `provision-db.sh`.
- Admin user: recreated by the entrypoint from the Secret.
- `/data` (Git clones): disposable, re-synced by the scheduler.

The database **data** does not follow Git (`local-path` is node-local). Migrate
it with a logical dump/restore, or by moving the Postgres PVC:

```bash
PGPW=$(kubectl -n homelab get secret pullini-secrets \
  -o jsonpath='{.data.DATABASE_URL}' | base64 -d | sed -E 's|postgres://pullini:([^@]+)@.*|\1|')

# on the old cluster
kubectl -n homelab exec postgresql-0 -- env PGPASSWORD="$PGPW" \
  pg_dump -Fc -U pullini -d pullini > pullini.dump

# on the new cluster, after provision-db.sh
kubectl -n homelab cp pullini.dump postgresql-0:/tmp/pullini.dump
kubectl -n homelab exec postgresql-0 -- env PGPASSWORD="$PGPW" \
  pg_restore --no-owner --no-acl -U pullini -d pullini /tmp/pullini.dump
```

## Troubleshooting

- **Pod never becomes Ready; logs show `DisallowedHost: Invalid HTTP_HOST
  header: '10.42.x.y:8000'`.** Kubelet probes connect to the Pod IP and send it
  as the `Host` header, which Django rejects because `DJANGO_ALLOWED_HOSTS` only
  lists `wiki.otakeessen.com`. The probes in `deployment.yaml` therefore set
  `httpHeaders: [{name: Host, value: wiki.otakeessen.com}]`. (A `301` from
  `SECURE_SSL_REDIRECT` still counts as probe success.)
- **`CreateContainerConfigError`.** `pullini-secrets` is missing in namespace
  `homelab` — create it before the Deployment rolls out.
- **`migrate` loops on startup.** The `pullini` role/database is not provisioned
  or `DATABASE_URL` is wrong — run `provision-db.sh`.

## Rollback

```bash
flux suspend kustomization apps -n flux-system     # stop Flux changing apps
kubectl -n homelab scale deploy/pullini --replicas=0
```

Re-pin the previous digest (revert the pin PR) and `flux resume`. The database
and PVC are untouched, so this is lossless.
