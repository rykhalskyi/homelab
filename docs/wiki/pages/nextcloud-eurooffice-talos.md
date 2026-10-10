---
tags: [nextcloud, talos, kubernetes, flux, gitops, cnpg, cloudnativepg, eurooffice, onlyoffice, documentserver, lan, sops]
date: 2026-10-10
source_count: 0
---

# Nextcloud + Euro-Office on Talos (LAN-only)

A **clean-install** Nextcloud with the Euro-Office DocumentServer on the `talos`
cluster. It mirrors [[Nextcloud on k3s (custom image + Helm chart)]] and
[[Euro-Office on k3s]], adapted to the Talos cluster's parts: the database is a
dedicated CloudNativePG `Cluster` (not Bitnami), storage is the dynamic
`local-path` StorageClass (not a static PV), and it is **LAN-only** for now
(the k8s cluster already owns `cloud.otakeessen.com` / `office.otakeessen.com`).

> **Status (2026-10-10): manifests created; not yet applied.** Phase A is
> LAN-only; Phase B (public via Cloudflare) is a later change.

## Differences from k8s (and why)

| Thing | k8s | talos |
|-------|-----|-------|
| Namespace | `homelab` | `nextcloud` (self-contained) |
| Database | standalone Bitnami Postgres `HelmRelease` | dedicated CNPG `Cluster nextcloud` |
| DB credentials | out-of-band `nextcloud-db` Secret | same Secret, also used as CNPG `bootstrap.initdb.secret` |
| Storage | static local PV for data + `nextcloud-html` PVC | both dynamic `local-path` PVCs |
| External storage | NAS over NFS | none |
| Exposure | Cloudflare wildcard tunnel → Traefik | LAN-only Traefik on node-two `:80` |
| Hosts | `cloud./office.otakeessen.com` | `cloud-talos./office-talos.homelab.local` |
| `TRUSTED_PROXIES` | `10.42.0.0/16` (k3s) | `10.244.0.0/16` (Talos/Cilium pod CIDR) |
| Scheme middleware | force `X-Forwarded-Proto: https` | omitted (plain HTTP on LAN) |

The HelmRelease has **no `dependsOn`**: on k8s it waited on the `postgresql`
`HelmRelease`, but here the DB is a CNPG CR. Instead the Pod retries until
`nextcloud-rw` accepts connections, and the `startupProbe` (60 × 10s) gives the
first-boot `occ maintenance:install` a full window.

## Pieces

| File | Role |
|------|------|
| `infra/clusters/talos/infrastructure/sources/nextcloud.yaml` | `HelmRepository` → `https://nextcloud.github.io/helm/` |
| `infra/clusters/talos/apps/nextcloud/namespace.yaml` | `Namespace: nextcloud` |
| `infra/clusters/talos/apps/nextcloud/storage.yaml` | `nextcloud-html` (20Gi) + `nextcloud-data` (100Gi) `local-path` PVCs |
| `infra/clusters/talos/apps/nextcloud/db-cluster.yaml` | CNPG `Cluster nextcloud` (PG 18.4, 1 instance) |
| `infra/clusters/talos/apps/nextcloud/helmrelease.yaml` | the Nextcloud `HelmRelease` (+ Redis subchart, custom image) |
| `infra/clusters/talos/apps/nextcloud/kustomization.yaml` | bundles the Nextcloud layer |
| `infra/clusters/talos/apps/eurooffice/*` | DocumentServer Deployment/Service/PVC/Middleware/Ingress |
| `infra/clusters/talos/apps/secrets/*.sops.yaml` | **local only**, out-of-band Secrets |
| `.github/workflows/update-nextcloud-image-pin.yml` | pins the image digest in **both** clusters' HelmReleases |

## Image

The custom `ghcr.io/rykhalskyi/homelab-nextcloud` image (byebyemoneylist baked at
`/opt`, copied into `custom_apps` by the `before-starting` hook) is shared with
k8s. `update-nextcloud-image-pin.yml` now rewrites the pin in both
`infra/clusters/k8s/apps/nextcloud/helmrelease.yaml` and
`infra/clusters/talos/apps/nextcloud/helmrelease.yaml`, so the two clusters stay
in lockstep. See [[Releasing a new Nextcloud image (byebyemoneylist app)]].

## Secrets (out of band, never in Git)

The `nextcloud` namespace needs five Secrets, stored SOPS-encrypted under
`infra/clusters/talos/apps/secrets/` (gitignored — see [[Secrets with SOPS + age
(local, out-of-band)]]):

| Secret | Keys |
|--------|------|
| `nextcloud-db` | `username`, `password` (CNPG `initdb` + chart `externalDatabase`) |
| `nextcloud-admin` | `nextcloud-username`, `nextcloud-password` |
| `nextcloud-redis` | `redis-password` |
| `eurooffice-jwt` | `JWT_SECRET` |
| `byebyemoneylist` | `SILICONFLOW_API_KEY` |

Create/edit and apply:

```bash
sops infra/clusters/talos/apps/secrets/nextcloud-db.sops.yaml   # and the others
bash infra/clusters/talos/apps/secrets/apply.sh                 # CTX=talos by default
kubectl --context talos -n nextcloud get secret
```

`nextcloud-db` is deliberately shared: `bootstrap.initdb.secret` makes CNPG
create the `nextcloud` owner with that password, and the chart uses the same
Secret — one source of truth, no operator-generated `nextcloud-app` Secret.

## Deploy

Commit the manifests and let Flux reconcile (or force it):

```bash
flux reconcile kustomization infrastructure -n flux-system --with-source
kubectl --context talos -n nextcloud get cluster,pods,pvc -w
# Nextcloud first boot runs maintenance:install; wait for deploy/nextcloud Ready
kubectl --context talos -n nextcloud get pods
```

Add client hosts entries:

```
192.168.2.234 cloud-talos.homelab.local office-talos.homelab.local
```

then open `http://cloud-talos.homelab.local/`.

## Wire the Euro-Office connector

The `eurooffice` Nextcloud app (connector) is installed with `occ` after the
Pod is up — the same steps as [[Euro-Office on k3s]], for the `nextcloud`
namespace and LAN URLs:

```bash
NC="kubectl --context talos -n nextcloud exec deploy/nextcloud -c nextcloud -- php /var/www/html/occ"
$NC app:install eurooffice && $NC app:enable eurooffice
$NC config:app:set eurooffice DocumentServerUrl         --value="http://office-talos.homelab.local/"
$NC config:app:set eurooffice DocumentServerInternalUrl --value="http://eurooffice.nextcloud.svc.cluster.local/"
$NC config:app:set eurooffice StorageUrl                --value="http://nextcloud.nextcloud.svc.cluster.local:8080/"
$NC config:app:set eurooffice jwt_secret  --value="$(kubectl --context talos -n nextcloud get secret eurooffice-jwt -o jsonpath='{.data.JWT_SECRET}' | base64 -d)"
$NC config:app:set eurooffice jwt_header  --value="Authorization"
$NC config:app:set eurooffice sameTab     --value=true
$NC config:system:set overwrite.cli.url --value=http://cloud-talos.homelab.local
$NC config:system:set trusted_domains 2 --value=nextcloud.nextcloud.svc.cluster.local
$NC config:system:set trusted_domains 3 --value=nextcloud
```

These app/system settings live in the database / `config.php`, not Git, so
re-run them after a rebuild from scratch.

## Verify

```bash
kubectl --context talos -n nextcloud get cluster nextcloud   # Cluster in healthy state
kubectl --context talos -n nextcloud get pods                # nextcloud, redis, eurooffice, nextcloud-1
$NC status
$NC eurooffice:documentserver --check
curl -s http://office-talos.homelab.local/healthcheck        # true (from the LAN)
```

Then create/open a `.docx`/`.xlsx`/`.pptx` in the browser and edit it.

## Phase B — public via Cloudflare (later)

When the talos instance should be reachable from outside the LAN:

1. Deploy `cloudflared` to the talos cluster (Deployment + tunnel/credentials
   Secret) and add new public hostnames — `cloud.`/`office.otakeessen.com`
   already belong to k8s, so use distinct ones (e.g. `cloud2.`/`office2.`).
2. Add an `eurooffice-forwarded-proto` Middleware (force `X-Forwarded-Proto:
   https`) and reference it from the Ingress — the mixed-content gotcha in
   [[Euro-Office on k3s]] applies once TLS terminates at the edge.
3. Switch the Nextcloud `host`/`trustedDomains`, the ingress host, and
   `overwrite.cli.url` to the public URL, and re-run the connector `occ`
   settings.

## Gotchas

- **No DB `dependsOn`.** The CNPG `Cluster` is not a HelmRelease, so the
  Nextcloud Pod may briefly crash-loop until `nextcloud-rw` is up; the startup
  probe covers it. An optional `wait-for-db` init container would remove the
  noise.
- **Redis subchart images.** The chart's bundled Bitnami Redis may need
  `global.security.allowInsecureImages: true` if Bitnami's registry move breaks
  the pull (the k8s standalone Postgres needed it).
- **`TRUSTED_PROXIES`** must match the live pod CIDR (`10.244.0.0/16` on
  Talos/Cilium).
- **Node capacity.** `node-two` is a single control-plane node; the Euro-Office
  DocumentServer wants ~2–4 GB RAM (`limits.memory: 3Gi`).
- **Backups** are not configured for the `nextcloud` CNPG `Cluster` yet — add a
  `barmanObjectStore` + `ScheduledBackup` like [[CloudNativePG on Talos
  (PostgreSQL + MinIO backups)]] when it matters.
- **Image pin sync** is automated for both clusters by
  `update-nextcloud-image-pin.yml`; a manual pin must update both files.
